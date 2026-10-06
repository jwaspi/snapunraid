#!/bin/bash
#
# install_snapraid.sh - fetch a prebuilt SnapRAID binary and link it into place.
#
# No compiler / toolchain needed. SnapRAID publishes official release assets;
# the Slackware .txz (Unraid is Slackware-based) contains a native x86_64
# binary linked against glibc/libm/libblkid - all of which already ship on
# Unraid. We download that package, verify its SHA256 against the release,
# extract the one binary, and persist it to the boot flash so it survives
# reboots.
#
# Unraid's root filesystem is RAM-based - anything in /usr/local/sbin is LOST
# on every reboot unless it's persisted on the boot flash (/boot/...) and
# relinked back into place at every boot/array start (see event/started).
#
# Modes:
#   (default)          install if missing; fast no-op if already installed.
#   --force-redownload  re-fetch and replace the binary.
#   --update            check the latest release and upgrade if it is newer.
#   --check             check the latest release and record whether an update
#                       is available, WITHOUT installing. Cheap when cached.
#
# The "latest" version is resolved from the GitHub releases API so the plugin
# tracks upstream. When the API is unreachable it falls back to the pinned
# release below (which must always be a valid, checksummed download).
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Pinned release - the fallback used when the GitHub API can't be reached, and
# the version a fresh install bootstraps with. SNAPRAID_SHA256 is of the whole
# .txz archive and is verified before we trust its contents. Keep URL, SHA256
# and BIN_PATH in sync when bumping; the API path verifies against the digest
# GitHub reports for the asset instead.
# ---------------------------------------------------------------------------
SNAPRAID_VERSION="14.10"
SNAPRAID_URL="https://github.com/amadvance/snapraid/releases/download/v${SNAPRAID_VERSION}/snapraid-${SNAPRAID_VERSION}-x86_64-1_am.txz"
SNAPRAID_SHA256="6930d629c73b5307ec32277310ed13887b1bd051e30dc41c75b4752040032d1c"
SNAPRAID_BIN_PATH="usr/bin/snapraid"

API_URL="https://api.github.com/repos/amadvance/snapraid/releases/latest"
# Don't hit the GitHub API more often than this on automatic checks.
CHECK_TTL=21600   # 6 hours

PERSIST_DIR="${PLUGIN_HOME}/bin"                 # /boot/config/plugins/snapunraid/bin - survives reboot
TARGET_BIN="${SRE_TARGET_BIN:-/usr/local/sbin/snapraid}"   # where sync.sh/scrub.sh expect it on PATH (override is for tests)
DL_DIR="/tmp/snapunraid-download"

FORCE_REDOWNLOAD=0
MODE="install"
for arg in "$@"; do
    case "$arg" in
        --force-redownload) FORCE_REDOWNLOAD=1 ;;
        --update)           MODE="update" ;;
        --check)            MODE="check" ;;
    esac
done

mkdir -p "$PERSIST_DIR"

sre_install_log() {
    echo "$1"
    sre_write_state "install_snapraid_message" "$1"
}

# ---------------------------------------------------------------------------
# Version of the binary currently installed (just the numeric part), or "".
# Prefers TARGET_BIN (where this script installs) so it always reflects what
# we manage, falling back to whatever is first on PATH.
# ---------------------------------------------------------------------------
installed_version() {
    local bin=""
    if [[ -x "$TARGET_BIN" ]]; then
        bin="$TARGET_BIN"
    elif command -v snapraid >/dev/null 2>&1; then
        bin="$(command -v snapraid)"
    else
        return 1
    fi
    "$bin" --version 2>/dev/null | head -1 | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -1 | sed 's/^v//'
}

record_installed() {
    local ver="$1" desc="$2"
    if [[ -n "$ver" ]]; then
        # Prefix the display strings with "v" so the state writer stores them
        # as JSON strings. A bare dotted value like 14.10 would otherwise be
        # stored as the JSON number 14.1 (trailing zero dropped), misreporting
        # the version in the UI. Comparisons use the *_ver_num fields.
        sre_write_state "snapraid_installed" "true" \
            "snapraid_version" "$desc" \
            "snapraid_installed_ver" "v${ver}" \
            "snapraid_installed_ver_num" "$(sre_snapraid_ver_num "$ver")"
    else
        sre_write_state "snapraid_installed" "true" "snapraid_version" "$desc"
    fi
}

# ---------------------------------------------------------------------------
# Resolve the latest release. Prints "<version>\t<url>\t<sha256>\t<source>".
# Uses the GitHub API first; falls back to the pinned release. Never partial:
# the fallback is always a complete, checksummed triple.
# ---------------------------------------------------------------------------
resolve_latest() {
    local json tag asset_name asset_url asset_digest
    if json=$(curl -fsSL --max-time 20 "$API_URL" 2>/dev/null) && [[ -n "$json" ]]; then
        tag=$(jq -r '.tag_name // ""' <<<"$json" 2>/dev/null)
        # Prefer the Slackware .txz (the format this plugin has always used).
        asset_name=$(jq -r '[.assets[] | select(.name | endswith(".txz"))][0].name // ""' <<<"$json" 2>/dev/null)
        asset_url=$(jq -r '[.assets[] | select(.name | endswith(".txz"))][0].browser_download_url // ""' <<<"$json" 2>/dev/null)
        asset_digest=$(jq -r '[.assets[] | select(.name | endswith(".txz"))][0].digest // ""' <<<"$json" 2>/dev/null)
        if [[ "$tag" =~ ^v[0-9] && -n "$asset_name" && -n "$asset_url" ]]; then
            # Digest looks like "sha256:<hex>"; a release without it (older
            # GitHub schemas) omits the field, in which case fall back to the
            # pinned hash only if the version matches it, else refuse to trust.
            asset_digest="${asset_digest#sha256:}"
            if [[ -z "$asset_digest" ]]; then
                if [[ "${tag#v}" == "$SNAPRAID_VERSION" ]]; then
                    asset_digest="$SNAPRAID_SHA256"
                else
                    return 1
                fi
            fi
            printf '%s\t%s\t%s\tgithub-api\n' "${tag#v}" "$asset_url" "$asset_digest"
            return 0
        fi
    fi
    printf '%s\t%s\t%s\tpinned\n' "$SNAPRAID_VERSION" "$SNAPRAID_URL" "$SNAPRAID_SHA256"
}

# ---------------------------------------------------------------------------
# Download + verify + extract + install <version> from <url>, checking <sha>.
# ---------------------------------------------------------------------------
fetch_and_install() {
    local version="$1" url="$2" sha="$3"

    rm -rf "$DL_DIR"
    mkdir -p "$DL_DIR"
    cd "$DL_DIR" || exit 1

    sre_install_log "Downloading prebuilt SnapRAID ${version}..."
    if ! curl -fsSL --max-time 300 -o snapraid.txz "$url"; then
        MSG="Download failed. Check this system has internet access to github.com, then retry."
        sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
        echo "ERROR: $MSG" >&2
        return 1
    fi

    local actual_sha
    actual_sha=$(sha256sum snapraid.txz | awk '{print $1}')
    if [[ "$actual_sha" != "$sha" ]]; then
        MSG="Checksum mismatch on downloaded package - refusing to use it. Expected ${sha}, got ${actual_sha}."
        sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
        echo "ERROR: $MSG" >&2
        return 1
    fi

    sre_install_log "Checksum verified. Extracting binary..."
    local bin=""
    if tar -xf snapraid.txz -C . "$SNAPRAID_BIN_PATH" 2>/dev/null; then
        bin="./${SNAPRAID_BIN_PATH}"
    else
        rm -rf extracted && mkdir extracted
        if ! tar -xf snapraid.txz -C extracted; then
            MSG="Could not extract the prebuilt package."
            sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
            echo "ERROR: $MSG" >&2
            return 1
        fi
        bin="./extracted/${SNAPRAID_BIN_PATH}"
    fi

    if [[ ! -f "$bin" ]] || ! chmod 755 "$bin" 2>/dev/null || ! "$bin" --version >/dev/null 2>&1; then
        MSG="Extracted binary is not a valid SnapRAID executable."
        sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
        echo "ERROR: $MSG" >&2
        return 1
    fi

    # Persist to the boot flash so it survives reboots, then copy into RAM
    # (/usr/local/sbin is tmpfs; the flash is vfat and cannot exec binaries).
    local persist_bin="${PERSIST_DIR}/snapraid-${version}"
    cp "$bin" "$persist_bin"
    chmod 755 "$persist_bin"
    cp -f "$persist_bin" "$TARGET_BIN"
    chmod 755 "$TARGET_BIN"

    local new_ver desc
    new_ver="$(installed_version)"
    desc="$("$TARGET_BIN" --version 2>&1 | head -1)"
    record_installed "$new_ver" "$desc"
    sre_write_state "install_snapraid_status" "ok"
    sre_install_log "OK: installed ${desc}. Persisted to ${persist_bin} so it survives reboots."

    cd /
    rm -rf "$DL_DIR"
    return 0
}

# ---------------------------------------------------------------------------
# --check: resolve latest, compare to installed, record state. Cached.
# ---------------------------------------------------------------------------
do_check() {
    local inst latest latest_num inst_num src checked now
    inst="$(installed_version)"

    # Honour the cache unless there is nothing cached yet.
    checked=$(sre_read_state_json | jq -r '.snapraid_update_checked // 0' 2>/dev/null)
    now=$(date +%s)
    if [[ -n "$inst" && -n "$checked" && "$checked" -gt 0 ]] && (( now - checked < CHECK_TTL )); then
        # Still refresh the installed version (cheap) but skip the network.
        record_installed "$inst" "$(snapraid --version 2>&1 | head -1)"
        sre_write_state "snapraid_update_available" "$(sre_read_state_json | jq -r '.snapraid_update_available // false' 2>/dev/null)"
        echo "OK: using cached update check (installed v${inst})."
        return 0
    fi

    local line
    if line="$(resolve_latest)"; then
        IFS=$'\t' read -r latest _url _sha src <<<"$line"
    else
        # API present but unusable (no .txz / no digest): fall back to pinned.
        latest="$SNAPRAID_VERSION"; src="pinned"
    fi

    inst_num=$(sre_snapraid_ver_num "${inst:-0}")
    latest_num=$(sre_snapraid_ver_num "$latest")

    local avail=false
    if [[ -n "$inst" ]] && (( latest_num > inst_num )); then avail=true; fi

    if [[ -n "$inst" ]]; then record_installed "$inst" "$(snapraid --version 2>&1 | head -1)"; fi
    sre_write_state \
        "snapraid_latest_version" "v${latest}" \
        "snapraid_latest_ver_num" "$latest_num" \
        "snapraid_update_available" "$avail" \
        "snapraid_update_checked" "$now" \
        "snapraid_latest_source" "$src"

    if [[ "$avail" == "true" ]]; then
        sre_install_log "Update available: SnapRAID ${latest} (installed ${inst})."
    else
        sre_install_log "SnapRAID is up to date (${inst:-none}). Latest ${latest}."
    fi
}

# ---------------------------------------------------------------------------
# --update: upgrade to the latest release if it is newer than installed.
# ---------------------------------------------------------------------------
do_update() {
    local inst line latest url sha src
    inst="$(installed_version)"
    if ! line="$(resolve_latest)"; then
        sre_write_state "install_snapraid_status" "error" \
            "install_snapraid_message" "Could not determine the latest SnapRAID release (GitHub API unavailable and pinned version unusable)."
        echo "ERROR: could not determine the latest SnapRAID release." >&2
        return 1
    fi
    IFS=$'\t' read -r latest url sha src <<<"$line"

    if [[ -n "$inst" ]] && sre_version_ge "$inst" "$latest"; then
        record_installed "$inst" "$(snapraid --version 2>&1 | head -1)"
        sre_write_state "install_snapraid_status" "ok" "snapraid_update_available" "false" \
            "snapraid_latest_version" "v${latest}" "snapraid_update_checked" "$(date +%s)" \
            "snapraid_latest_source" "$src"
        sre_install_log "OK: SnapRAID ${inst} is already the latest (${latest})."
        return 0
    fi

    sre_write_state "install_snapraid_status" "running"
    if fetch_and_install "$latest" "$url" "$sha"; then
        sre_write_state "snapraid_update_available" "false" \
            "snapraid_latest_version" "v${latest}" "snapraid_update_checked" "$(date +%s)" \
            "snapraid_latest_source" "$src"
        return 0
    fi
    return 1
}

case "$MODE" in
    check)  do_check; exit $? ;;
    update) do_update; exit $? ;;
esac

# ---------------------------------------------------------------------------
# Install mode.
#
# Fast path 1: already installed and working. Still refresh the recorded
# version in case the binary on PATH changed underneath us.
# ---------------------------------------------------------------------------
if [[ $FORCE_REDOWNLOAD -eq 0 ]] && command -v snapraid >/dev/null 2>&1 && snapraid --version >/dev/null 2>&1; then
    record_installed "$(installed_version)" "$(snapraid --version 2>&1 | head -1)"
    echo "OK: snapraid already installed: $(snapraid --version 2>&1 | head -1)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Fast path 2: previously downloaded binary persisted on the boot flash -
# this is the path taken on every normal boot, no downloading needed.
# ---------------------------------------------------------------------------
PERSIST_BIN="${PERSIST_DIR}/snapraid-${SNAPRAID_VERSION}"
if [[ $FORCE_REDOWNLOAD -eq 0 && -f "$PERSIST_BIN" ]]; then
    # Copy the persisted binary from flash into RAM (/usr/local/sbin is tmpfs).
    # The boot flash is vfat and CANNOT execute binaries - a symlink to a flash
    # file returns "Permission denied". Copying into tmpfs restores exec bits.
    cp -f "$PERSIST_BIN" "$TARGET_BIN" && chmod 755 "$TARGET_BIN"
    if snapraid --version >/dev/null 2>&1; then
        record_installed "$(installed_version)" "$(snapraid --version 2>&1 | head -1)"
        sre_install_log "OK: restored persisted snapraid ${SNAPRAID_VERSION} from flash."
        exit 0
    else
        sre_install_log "WARN: persisted binary failed to run, will redownload."
    fi
fi

# ---------------------------------------------------------------------------
# Slow path: download + verify + extract the prebuilt binary. Prefer the
# latest release (so a fresh install is current) and fall back to the pinned
# version if the API is unreachable.
# ---------------------------------------------------------------------------
sre_write_state "snapraid_installed" "false" "install_snapraid_status" "running"

if line="$(resolve_latest)"; then
    IFS=$'\t' read -r BOOT_VERSION BOOT_URL BOOT_SHA BOOT_SRC <<<"$line"
else
    BOOT_VERSION="$SNAPRAID_VERSION"; BOOT_URL="$SNAPRAID_URL"; BOOT_SHA="$SNAPRAID_SHA256"; BOOT_SRC="pinned"
fi

fetch_and_install "$BOOT_VERSION" "$BOOT_URL" "$BOOT_SHA"
RC=$?
if [[ $RC -eq 0 ]]; then
    sre_write_state "snapraid_latest_version" "v${BOOT_VERSION}" \
        "snapraid_latest_ver_num" "$(sre_snapraid_ver_num "$BOOT_VERSION")" \
        "snapraid_update_available" "false" "snapraid_update_checked" "$(date +%s)" \
        "snapraid_latest_source" "$BOOT_SRC"
fi
exit $RC
