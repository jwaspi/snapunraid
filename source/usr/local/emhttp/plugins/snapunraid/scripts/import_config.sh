#!/bin/bash
#
# import_config.sh - import an existing snapraid.conf into the plugin.
#
# Usage: import_config.sh [path]
#   path   path to an existing snapraid.conf. If omitted, common locations
#          are auto-detected.
#
# Parses parity / parity-2 / content / data / exclude lines, converts the
# absolute /mnt/... paths to the plugin's relative form, writes settings.ini
# (preserving alert keys etc.), and regenerates snapraid.conf via genconfig.sh
# (which re-validates mounts / raw devices).
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONF_PATH="${1:-}"

# Auto-detect common locations if no path given
if [[ -z "$CONF_PATH" ]]; then
    for cand in /boot/config/plugins/snapraid/snapraid.conf \
                /etc/snapraid.conf \
                /boot/config/snapraid.conf; do
        if [[ -f "$cand" ]]; then
            CONF_PATH="$cand"
            break
        fi
    done
fi

if [[ -z "$CONF_PATH" || ! -f "$CONF_PATH" ]]; then
    echo '{"ok":false,"error":"snapraid.conf not found. Provide a path to an existing config."}'
    exit 1
fi

# Convert an absolute /mnt/... path to the plugin's relative form.
#   parity  /mnt/disks/snapunraid/snapraid.parity  -> disks/snapunraid
#   content /mnt/disk1/.snapraid/snapraid.content  -> disk1
#   data    /mnt/disks/pool/                       -> disks/pool
sre_rel() {
    local p="$1" kind="$2"
    p="${p#/mnt/}"
    p="${p%/}"
    case "$kind" in
        parity)  p="${p%/*}" ;;                 # drop the parity filename
        content) p="${p%/*}"; p="${p%/*}" ;;    # drop filename + its dir (.snapraid)
    esac
    echo "$p"
}

PARITY=""
PARITY2=""
DATA=()
CONTENT=()
EXCLUDES=()

while IFS= read -r line; do
    line="${line%%#*}"                       # strip comments
    line="${line#"${line%%[![:space:]]*}"}"  # strip leading whitespace
    [[ -z "$line" ]] && continue
    case "$line" in
        parity\ *)   PARITY=$(sre_rel "$(awk '{print $2}' <<<"$line")" parity) ;;
        parity-2\ *) PARITY2=$(sre_rel "$(awk '{print $2}' <<<"$line")" parity) ;;
        data\ *)     DATA+=("$(sre_rel "$(awk '{print $3}' <<<"$line")" data)") ;;
        content\ *)  CONTENT+=("$(sre_rel "$(awk '{print $2}' <<<"$line")" content)") ;;
        exclude\ *)  EXCLUDES+=("$(awk '{print $2}' <<<"$line")") ;;
    esac
done < "$CONF_PATH"

if [[ -z "$PARITY" || ${#DATA[@]} -eq 0 ]]; then
    echo '{"ok":false,"error":"No parity or data disks found in the config."}'
    exit 1
fi

# Write settings.ini (sre_set_setting only touches the keys we set, so alert
# toggles, schedule, threshold etc. are preserved).
sre_set_setting "PARITY_PATH" "$PARITY"
sre_set_setting "PARITY2_PATH" "$PARITY2"
sre_set_setting "DATA_DISKS" "$(IFS=,; echo "${DATA[*]}")"
sre_set_setting "CONTENT_DISKS" "$(IFS=,; echo "${CONTENT[*]}")"
sre_set_setting "EXCLUDES" "$(IFS=,; echo "${EXCLUDES[*]}")"

# Regenerate snapraid.conf (validates mounts / raw devices / parity-2 != parity)
if ! GENOUT=$(bash "${SCRIPT_DIR}/genconfig.sh" 2>&1); then
    echo "{\"ok\":false,\"error\":\"$(echo "$GENOUT" | head -1)\"}"
    exit 1
fi

echo "{\"ok\":true,\"parity\":\"$PARITY\",\"parity2\":\"$PARITY2\",\"data\":\"$(IFS=,; echo "${DATA[*]}")\",\"content\":\"$(IFS=,; echo "${CONTENT[*]}")\",\"excludes\":\"$(IFS=,; echo "${EXCLUDES[*]}")\"}"
