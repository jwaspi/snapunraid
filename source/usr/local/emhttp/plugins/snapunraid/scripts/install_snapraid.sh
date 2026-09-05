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
# Strategy:
#   1. If a working binary is already at TARGET_BIN, do nothing (fast path).
#   2. If a previously downloaded/extracted binary exists on the persistent
#      flash copy, just symlink it into place (fast path, no downloading -
#      this is what runs on every boot via the plugin's event hook).
#   3. Otherwise download the .txz, verify its checksum, and extract the
#      binary (slow path - only once, or after the pinned version changes).
#
# Usage: install_snapraid.sh [--force-redownload]
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Pinned release. These three must stay in sync:
#   URL       - official GitHub release asset
#   SHA256    - of the whole .txz archive (verified before we trust its contents)
#   BIN_PATH  - path of the binary inside the archive
# Update all together when bumping the pinned SnapRAID version.
# ---------------------------------------------------------------------------
SNAPRAID_VERSION="14.9"
SNAPRAID_URL="https://github.com/amadvance/snapraid/releases/download/v${SNAPRAID_VERSION}/snapraid-${SNAPRAID_VERSION}-x86_64-1_am.txz"
SNAPRAID_SHA256="40cee688cb1a322810eaac4e3655313c0075b791e18783bec2588084a9e47f09"
SNAPRAID_BIN_PATH="usr/bin/snapraid"

PERSIST_DIR="${PLUGIN_HOME}/bin"                 # /boot/config/plugins/snapunraid/bin - survives reboot
PERSIST_BIN="${PERSIST_DIR}/snapraid-${SNAPRAID_VERSION}"
TARGET_BIN="/usr/local/sbin/snapraid"            # where sync.sh/scrub.sh expect to find it on PATH
DL_DIR="/tmp/snapunraid-download"

FORCE_REDOWNLOAD=0
[[ "$1" == "--force-redownload" ]] && FORCE_REDOWNLOAD=1

mkdir -p "$PERSIST_DIR"

sre_install_log() {
    echo "$1"
    sre_write_state "install_snapraid_message" "$1"
}

# ---------------------------------------------------------------------------
# Fast path 1: already installed and working
# ---------------------------------------------------------------------------
if [[ $FORCE_REDOWNLOAD -eq 0 ]] && command -v snapraid >/dev/null 2>&1 && snapraid --version >/dev/null 2>&1; then
    sre_write_state "snapraid_installed" "true" "snapraid_version" "$(snapraid --version 2>&1 | head -1)"
    echo "OK: snapraid already installed: $(snapraid --version 2>&1 | head -1)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Fast path 2: previously downloaded binary persisted on the boot flash -
# this is the path taken on every normal boot, no downloading needed.
# ---------------------------------------------------------------------------
if [[ $FORCE_REDOWNLOAD -eq 0 && -f "$PERSIST_BIN" ]]; then
    # Copy the persisted binary from flash into RAM (/usr/local/sbin is tmpfs).
    # The boot flash is vfat and CANNOT execute binaries - a symlink to a flash
    # file returns "Permission denied". Copying into tmpfs restores exec bits.
    cp -f "$PERSIST_BIN" "$TARGET_BIN" && chmod 755 "$TARGET_BIN"
    if snapraid --version >/dev/null 2>&1; then
        sre_write_state "snapraid_installed" "true" "snapraid_version" "$(snapraid --version 2>&1 | head -1)"
        sre_install_log "OK: restored persisted snapraid ${SNAPRAID_VERSION} from flash."
        exit 0
    else
        sre_install_log "WARN: persisted binary failed to run, will redownload."
    fi
fi

# ---------------------------------------------------------------------------
# Slow path: download + verify + extract the prebuilt binary.
# ---------------------------------------------------------------------------
sre_write_state "snapraid_installed" "false" "install_snapraid_status" "running"

rm -rf "$DL_DIR"
mkdir -p "$DL_DIR"
cd "$DL_DIR" || exit 1

sre_install_log "Downloading prebuilt SnapRAID ${SNAPRAID_VERSION}..."
if ! curl -fsSL -o snapraid.txz "$SNAPRAID_URL"; then
    MSG="Download failed. Check this system has internet access to github.com, then retry."
    sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
    echo "ERROR: $MSG" >&2
    exit 1
fi

ACTUAL_SHA256=$(sha256sum snapraid.txz | awk '{print $1}')
if [[ "$ACTUAL_SHA256" != "$SNAPRAID_SHA256" ]]; then
    MSG="Checksum mismatch on downloaded package - refusing to use it. Expected ${SNAPRAID_SHA256}, got ${ACTUAL_SHA256}."
    sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
    echo "ERROR: $MSG" >&2
    exit 1
fi

sre_install_log "Checksum verified. Extracting binary..."
# `.txz` is a plain tar.xz (Slackware package); Unraid ships bsdtar.
if ! tar -xf snapraid.txz -C . "$SNAPRAID_BIN_PATH" 2>/dev/null; then
    # fall back to extracting the whole archive if path-preserving extraction isn't supported
    rm -rf extracted && mkdir extracted
    if ! tar -xf snapraid.txz -C extracted; then
        MSG="Could not extract the prebuilt package."
        sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
        echo "ERROR: $MSG" >&2
        exit 1
    fi
    BIN="./extracted/${SNAPRAID_BIN_PATH}"
else
    BIN="./${SNAPRAID_BIN_PATH}"
fi

if [[ ! -x "$BIN" ]] || ! "$BIN" --version >/dev/null 2>&1; then
    MSG="Extracted binary is not a valid SnapRAID executable."
    sre_write_state "install_snapraid_status" "error" "install_snapraid_message" "$MSG"
    echo "ERROR: $MSG" >&2
    exit 1
fi

# Persist to the boot flash so it survives reboots, then copy into RAM
# (/usr/local/sbin is tmpfs; the flash is vfat and cannot exec binaries).
cp "$BIN" "$PERSIST_BIN"
chmod 755 "$PERSIST_BIN"
cp -f "$PERSIST_BIN" "$TARGET_BIN"
chmod 755 "$TARGET_BIN"

VERSION_STRING=$("$BIN" --version 2>&1 | head -1)
sre_write_state "snapraid_installed" "true" "install_snapraid_status" "ok" "snapraid_version" "$VERSION_STRING"
sre_install_log "OK: installed ${VERSION_STRING} (prebuilt). Persisted to ${PERSIST_BIN} so it survives reboots."

cd /
rm -rf "$DL_DIR"
exit 0
