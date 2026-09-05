#!/bin/bash
#
# status.sh - JSON status for the webGUI dashboard + disk discovery for Setup
#
# Usage:
#   status.sh state     -> current sync/scrub state (for Dashboard)
#   status.sh disks     -> array disks + pool disks available to protect (for Setup)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-state}"

case "$ACTION" in
    state)
        sre_read_state_json
        ;;
    history)
        # Persistent run history for the History tab (JSON array, newest first).
        sre_read_history
        ;;
    disks)
        # Discover array disks and pool/candidate mountpoints under /mnt, plus
        # raw unassigned block devices (e.g. /dev/sdg) for use as a dedicated,
        # unformatted SnapRAID parity disk. Pure bash + jq (python3 is not
        # guaranteed present on Unraid).
        disks_json="[]"
        skip=" user user0 disks remotes rootshare cache "

        # 1) Mounted array/pool disks under /mnt (potential data disks).
        for entry in /mnt/*; do
            name="$(basename "$entry")"
            path="/mnt/${name}"
            [[ -d "$path" ]] || continue
            mountpoint -q "$path" || continue
            size=0; used=0
            read -r b u < <(df -B1 --output=size,used "$path" 2>/dev/null | tail -n +2)
            [[ -n "$b" ]] && size="$b"
            [[ -n "$u" ]] && used="$u"
            if [[ "$skip" == *" $name "* ]]; then
                continue
            elif [[ "$name" == disk* ]]; then
                type="array"
            else
                type="pool"
            fi
            disks_json=$(jq -c --arg n "$name" --arg p "$path" --arg r "$name" --arg ty "$type" \
                --argjson sz "${size:-0}" --argjson us "${used:-0}" \
                '. + [{name:$n,path:$p,rel:$r,type:$ty,size_bytes:$sz,used_bytes:$us}]' \
                <<<"$disks_json")
        done

        # 1b) Unassigned Devices mounts under /mnt/disks/<name>. UD mounts
        #     unassigned disks at /mnt/disks by default; these are valid parity
        #     and data candidates. They're addressed as /mnt/disks/<name>, so
        #     rel (the settings.ini value) is "disks/<name>" - genconfig.sh
        #     re-expands it as /mnt/disks/<name>.
        for entry in /mnt/disks/*; do
            name="$(basename "$entry")"
            path="/mnt/disks/${name}"
            [[ -d "$path" ]] || continue
            mountpoint -q "$path" || continue
            size=0; used=0
            read -r b u < <(df -B1 --output=size,used "$path" 2>/dev/null | tail -n +2)
            [[ -n "$b" ]] && size="$b"
            [[ -n "$u" ]] && used="$u"
            disks_json=$(jq -c --arg n "$name" --arg p "$path" --arg r "disks/${name}" --arg ty "pool" \
                --argjson sz "${size:-0}" --argjson us "${used:-0}" \
                '. + [{name:$n,path:$p,rel:$r,type:$ty,size_bytes:$sz,used_bytes:$us}]' \
                <<<"$disks_json")
        done

        # 2) Raw unassigned whole disks as parity candidates. A genuinely free
        #    disk is one with NO child partitions/filesystems (e.g. /dev/sdg).
        #    Array disks (sda..) and drives with existing partitions are excluded
        #    because their data lives behind md/mounted partitions - only a bare
        #    whole-disk device is a valid raw parity target.
        while read -r dev size; do
            [[ -z "$dev" ]] && continue
            # skip loop/ram/zram pseudo-devices and the boot flash
            case "$dev" in
                loop*|ram*|zram*|sr*|sdp*) continue ;;
            esac
            # skip if whole disk has any child (partition) or any mounted member
            if lsblk -no MOUNTPOINTS "/dev/$dev" 2>/dev/null | grep -q .; then
                continue
            fi
            # must be a bare block device with no child partitions at all
            child=$(lsblk -n -o NAME "/dev/$dev" 2>/dev/null | wc -l)
            if [[ "$child" -ne 1 ]]; then
                continue
            fi
            # Use the STABLE by-id path, not /dev/sdX. sdX names change across
            # reboots and can point at a DIFFERENT disk - a raw parity path must
            # never be volatile. Prefer wwn, then ata/sata model-serial.
            byid=""
            for cand in /dev/disk/by-id/wwn-0x* /dev/disk/by-id/ata-*; do
                [[ -e "$cand" ]] || continue
                if [[ "$(readlink -f "$cand" 2>/dev/null)" == "/dev/$dev" ]]; then
                    if [[ "$cand" == *wwn-* ]]; then byid="$cand"; break; fi
                    [[ -z "$byid" ]] && byid="$cand"
                fi
            done
            [[ -n "$byid" ]] || byid="/dev/$dev"
            disks_json=$(jq -c --arg n "$dev" --arg p "$byid" --arg r "$byid" --arg ty "raw" \
                --argjson sz "${size:-0}" --argjson us "0" \
                '. + [{name:$n,path:$p,rel:$r,type:$ty,size_bytes:$sz,used_bytes:0}]' \
                <<<"$disks_json")
        done < <(lsblk -dn -o NAME,SIZE -b 2>/dev/null)

        echo "$disks_json"
        ;;
    status)
        # Cached snapraid status summary for the Dashboard. `snapraid status`
        # scans the array and can take a while, so we cache the parsed result
        # in state.json and only refresh it in the background when it's stale
        # (5 min). Returns the current cache immediately - never blocks.
        NOW=$(date +%s)
        CACHED=$(jq -r '.snapraid_status_fetched // 0' "$STATE_FILE" 2>/dev/null)
        if [[ -z "$CACHED" || $((NOW - CACHED)) -ge 300 ]]; then
            if ! pgrep -f 'status.sh status-refresh' >/dev/null 2>&1; then
                nohup bash "$0" status-refresh >/dev/null 2>&1 &
            fi
        fi
        jq -c '{file_count: (.snapraid_file_count // 0), file_size: (.snapraid_file_size // 0), use_percent: (.snapraid_use_percent // 0), parity_size: (.snapraid_parity_size // 0), parity_age_days: (.snapraid_parity_age_days // null), scrub_oldest_days: (.snapraid_scrub_oldest_days // null), scrub_median_days: (.snapraid_scrub_median_days // null), scrub_newest_days: (.snapraid_scrub_newest_days // null), fetched: (.snapraid_status_fetched // 0)}' "$STATE_FILE" 2>/dev/null
        ;;
    status-refresh)
        # Run `snapraid status --log` to capture machine-readable summary: tags,
        # parse them, and cache the result in state.json. Runs in the background
        # (kicked off by the `status` action) so the Dashboard never blocks.
        #
        # snapraid takes an exclusive lock for EVERY command, so `status` fails
        # with "SnapRAID is already in use!" while a sync/scrub holds it. Skip
        # the refresh then (keeping the last good cache) instead of clobbering
        # the Dashboard's file count with zeros.
        RUNNING=$(jq -r 'if .sync_status == "running" or .scrub_status == "running" then 1 else 0 end' "$STATE_FILE" 2>/dev/null)
        if [[ "$RUNNING" == "1" ]]; then
            exit 0
        fi
        TMPLOG=$(mktemp)
        timeout 120 snapraid --conf "$SNAPRAID_CONF" status --log ">>$TMPLOG" >/dev/null 2>&1
        FILE_COUNT=$(grep -oE '^summary:file_count:[0-9]+' "$TMPLOG" | cut -d: -f3)
        FILE_SIZE=$(grep -oE '^summary:file_size:[0-9]+' "$TMPLOG" | cut -d: -f3)
        USE_PERCENT=$(grep -oE '^summary:total_use_percent:[0-9]+' "$TMPLOG" | cut -d: -f3)
        PARITY_SIZE=$(grep -oE '^summary:parity_size:[0-9]+' "$TMPLOG" | cut -d: -f3)
        SCRUB_OLDEST=$(grep -oE '^summary:scrub_oldest_days:[0-9]+' "$TMPLOG" | cut -d: -f3)
        SCRUB_MEDIAN=$(grep -oE '^summary:scrub_median_days:[0-9]+' "$TMPLOG" | cut -d: -f3)
        SCRUB_NEWEST=$(grep -oE '^summary:scrub_newest_days:[0-9]+' "$TMPLOG" | cut -d: -f3)
        rm -f "$TMPLOG"

        # If the status command failed (lock race, timeout, disk error) there
        # are no summary tags - keep the previous cached values rather than
        # writing zeros that would make the Dashboard report an empty array.
        if [[ -z "$FILE_COUNT" ]]; then
            exit 0
        fi

        # Parity freshness: age of the parity file itself (updated on every sync).
        PARITY_PATH=$(sre_get_setting "PARITY_PATH" "")
        PARITY_FILE="/mnt/${PARITY_PATH}/snapraid.parity"
        PARITY_AGE=""
        if [[ -f "$PARITY_FILE" ]]; then
            PARITY_AGE=$(( ($(date +%s) - $(stat -c %Y "$PARITY_FILE")) / 86400 ))
        fi

        # Second parity disk (optional) - same freshness measure.
        PARITY2_PATH=$(sre_get_setting "PARITY2_PATH" "")
        PARITY2_AGE=""
        if [[ -n "$PARITY2_PATH" ]]; then
            PARITY2_FILE="/mnt/${PARITY2_PATH}/snapraid.parity-2"
            if [[ -f "$PARITY2_FILE" ]]; then
                PARITY2_AGE=$(( ($(date +%s) - $(stat -c %Y "$PARITY2_FILE")) / 86400 ))
            fi
        fi

        sre_write_state "snapraid_file_count" "${FILE_COUNT:-0}" \
            "snapraid_file_size" "${FILE_SIZE:-0}" \
            "snapraid_use_percent" "${USE_PERCENT:-0}" \
            "snapraid_parity_size" "${PARITY_SIZE:-0}" \
            "snapraid_parity_age_days" "${PARITY_AGE:-}" \
            "snapraid_parity2_age_days" "${PARITY2_AGE:-}" \
            "snapraid_scrub_oldest_days" "${SCRUB_OLDEST:-}" \
            "snapraid_scrub_median_days" "${SCRUB_MEDIAN:-}" \
            "snapraid_scrub_newest_days" "${SCRUB_NEWEST:-}" \
            "snapraid_status_fetched" "$(date +%s)"

        # Proactive health alerts (parity stale, disk offline, low space, scrub
        # overdue). Fast and deduplicated, so it's safe on every refresh.
        bash "${SCRIPT_DIR}/alerts.sh" check >/dev/null 2>&1
        ;;
    *)
        echo '{"error":"unknown action"}'
        exit 1
        ;;
esac
