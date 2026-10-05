#!/bin/bash
#
# alerts.sh - proactive health checks that fire Unraid notifications.
#
# Usage: alerts.sh check
#
# Runs the configured health alerts (Alerts tab). Each check is gated by its
# own toggle in settings.ini and, when it fires, is deduplicated by
# sre_alert_once so a persistent condition notifies at most once per day.
# Invoked daily by cron and at the end of every status-refresh.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-check}"

case "$ACTION" in
    check)
        # -------------------------------------------------------------------
        # 1) Parity stale - the parity file hasn't been refreshed by a sync
        #    in too long. Age comes from the cached status-refresh summary.
        # -------------------------------------------------------------------
        if sre_alert_enabled "ALERT_PARITY_STALE" "1"; then
            DAYS=$(sre_get_setting "ALERT_PARITY_STALE_DAYS" "30")
            AGE=$(jq -r '.snapraid_parity_age_days // ""' "$STATE_FILE" 2>/dev/null)
            if [[ -n "$AGE" && "$AGE" -ge "$DAYS" ]]; then
                sre_alert_once "alert_parity_stale_sent" "Parity is stale" \
                    "Parity is ${AGE} day(s) old (threshold ${DAYS}). Run a sync to refresh it." "warning"
            fi
        fi

        # -------------------------------------------------------------------
        # 2) Disk offline - a configured data or parity disk isn't mounted.
        #    A sync would treat a dropped disk as mass deletion, so this is
        #    worth knowing about before the next scheduled sync.
        # -------------------------------------------------------------------
        if sre_alert_enabled "ALERT_DISK_OFFLINE" "1"; then
            MISSING=()
            DATA_DISKS=$(sre_get_setting "DATA_DISKS" "")
            IFS=',' read -ra DD <<< "$DATA_DISKS"
            for d in "${DD[@]}"; do
                [[ -z "$d" ]] && continue
                mountpoint -q "/mnt/${d}" 2>/dev/null || MISSING+=("$d")
            done
            for p in "$(sre_get_setting "PARITY_PATH" "")" "$(sre_get_setting "PARITY2_PATH" "")"; do
                [[ -z "$p" ]] && continue
                mountpoint -q "/mnt/${p}" 2>/dev/null || MISSING+=("$p")
            done
            if [[ ${#MISSING[@]} -gt 0 ]]; then
                sre_alert_once "alert_disk_offline_sent" "Disk offline" \
                    "Configured disk(s) not mounted: ${MISSING[*]}. Fix before the next sync, or parity will be rewritten as if those files were deleted." "alert"
            fi
        fi

        # -------------------------------------------------------------------
        # 3) Parity disk low on space - the disk holding a parity file is
        #    nearly full. A sync rewrites parity to match the largest data
        #    disk, so it needs headroom to grow.
        # -------------------------------------------------------------------
        if sre_alert_enabled "ALERT_PARITY_SPACE" "1"; then
            PCT=$(sre_get_setting "ALERT_PARITY_SPACE_PCT" "10")
            for p in "$(sre_get_setting "PARITY_PATH" "")" "$(sre_get_setting "PARITY2_PATH" "")"; do
                [[ -z "$p" ]] && continue
                FREE_PCT=$(df -Pk "/mnt/${p}" 2>/dev/null | awk 'NR==2 {print 100-$5}')
                if [[ -n "$FREE_PCT" && "$FREE_PCT" -lt "$PCT" ]]; then
                    sre_alert_once "alert_parity_space_sent" "Parity disk low on space" \
                        "Parity disk '${p}' has only ${FREE_PCT}% free (threshold ${PCT}%). Free up space before the next sync." "warning"
                fi
            done
        fi

        # -------------------------------------------------------------------
        # 4) Scrub overdue - no scrub has run in too long.
        #
        #    This deliberately does NOT use snapraid's scrub_oldest_days.
        #    That value is the age of the single OLDEST block in the array, and
        #    snapraid only reports a "newest/median/oldest" spread; with the
        #    percentage-based scrub this plugin runs (-p 12 -o 10: 12% of the
        #    array, only blocks older than 10 days) the tail of the array is
        #    EXPECTED to age well past any fixed threshold even when scrubs run
        #    perfectly on schedule. On a large array where a large fraction of
        #    blocks have never been scrubbed, scrub_oldest_days sits high for
        #    weeks and the old check fired on a healthy, weekly-scrubbed array.
        #
        #    The actionable signal - and the thing within the operator's
        #    control - is whether the scrub job is running at all. So watch the
        #    last completed run rather than the block-age tail.
        # -------------------------------------------------------------------
        if sre_alert_enabled "ALERT_SCRUB_OVERDUE" "1"; then
            DAYS=$(sre_get_setting "ALERT_SCRUB_OVERDUE_DAYS" "30")
            LAST=$(jq -r '.scrub_finished // ""' "$STATE_FILE" 2>/dev/null)
            # No scrub has ever run (fresh install) - nothing to warn about yet.
            if [[ -n "$LAST" ]]; then
                SINCE=$(( ( $(date +%s) - LAST ) / 86400 ))
                if [[ "$SINCE" -ge "$DAYS" ]]; then
                    sre_alert_once "alert_scrub_overdue_sent" "Scrub overdue" \
                        "No scrub has completed in ${SINCE} day(s) (threshold ${DAYS}). Check the schedule, or run a scrub from the Dashboard." "warning"
                fi
            fi
        fi

        # -------------------------------------------------------------------
        # 5) Content file missing or stale - the .snapraid.content index files
        #    are what make sync possible. A missing one breaks the next sync;
        #    one older than the parity file suggests the last sync didn't
        #    update it. Both are worth knowing before the next scheduled run.
        # -------------------------------------------------------------------
        if sre_alert_enabled "ALERT_CONTENT_STALE" "1"; then
            CONTENT_DISKS=$(sre_get_setting "CONTENT_DISKS" "")
            PARITY_MTIME=$(stat -c %Y "/mnt/$(sre_get_setting "PARITY_PATH" "")/snapraid.parity" 2>/dev/null)
            # During a sync, parity is written first and the content files are
            # only rewritten at the very end, so content is transiently older
            # than parity. Skip the stale comparison while a sync is running to
            # avoid a false "content file stale" alert mid-sync.
            SYNC_RUNNING=$(jq -r '.sync_status // ""' "$STATE_FILE" 2>/dev/null)
            IFS=',' read -ra CD <<< "$CONTENT_DISKS"
            for d in "${CD[@]}"; do
                [[ -z "$d" ]] && continue
                CF="/mnt/${d}/.snapraid/snapraid.content"
                if [[ ! -f "$CF" ]]; then
                    sre_alert_once "alert_content_stale_sent" "Content file missing" \
                        "SnapRAID content file '${CF}' is missing. The next sync will fail until it is rebuilt." "alert"
                elif [[ -n "$PARITY_MTIME" && "$SYNC_RUNNING" != "running" ]]; then
                    CF_MTIME=$(stat -c %Y "$CF" 2>/dev/null)
                    if [[ -n "$CF_MTIME" && $(( PARITY_MTIME - CF_MTIME )) -gt 60 ]]; then
                        sre_alert_once "alert_content_stale_sent" "Content file stale" \
                            "Content file '${CF}' is older than the parity file. It may not have been updated by the last sync." "warning"
                    fi
                fi
            done
        fi

        # -------------------------------------------------------------------
        # 6) Parity file missing - if snapraid.parity doesn't exist, nothing
        #    is protected. Alert immediately rather than discovering it at
        #    sync time.
        # -------------------------------------------------------------------
        if sre_alert_enabled "ALERT_PARITY_MISSING" "1"; then
            P1=$(sre_get_setting "PARITY_PATH" "")
            P2=$(sre_get_setting "PARITY2_PATH" "")
            if [[ -n "$P1" && ! -f "/mnt/${P1}/snapraid.parity" ]]; then
                sre_alert_once "alert_parity_missing_sent" "Parity file missing" \
                    "Parity file '/mnt/${P1}/snapraid.parity' does not exist. Your data is not protected." "alert"
            fi
            if [[ -n "$P2" && ! -f "/mnt/${P2}/snapraid.parity-2" ]]; then
                sre_alert_once "alert_parity_missing_sent" "Parity-2 file missing" \
                    "Second parity file '/mnt/${P2}/snapraid.parity-2' does not exist." "alert"
            fi
        fi

        # -------------------------------------------------------------------
        # 7) Damaged files still unrecovered - if the last check/scrub found
        #    damaged files and they're still listed on the Recover tab, remind
        #    daily until they're restored from parity.
        # -------------------------------------------------------------------
        if sre_alert_enabled "ALERT_UNRECOVERED" "1"; then
            if [[ -f "$SNAPRAID_CONF" ]]; then
                COUNT=$(bash "${SCRIPT_DIR}/recover.sh" list 2>/dev/null | jq 'length' 2>/dev/null)
                if [[ -n "$COUNT" && "$COUNT" -gt 0 ]]; then
                    sre_alert_once "alert_unrecovered_sent" "Damaged files unrecovered" \
                        "${COUNT} damaged file(s) are still listed on the Recover tab. Restore them from parity." "warning"
                fi
            fi
        fi
        ;;
    *)
        echo '{"error":"unknown action"}'
        exit 1
        ;;
esac
