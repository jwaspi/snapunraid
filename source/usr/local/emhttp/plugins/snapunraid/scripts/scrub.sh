#!/bin/bash
#
# scrub.sh - run `snapraid scrub` to verify data against parity
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Ensure we run as a process-group leader so the webGUI can cancel us by
# signalling the whole group. The webGUI starts us with `setsid`, but cron
# does not - re-exec under setsid when we're not already a group leader.
if [[ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" != "$$" ]]; then
    exec setsid bash "$0" "$@"
fi

sre_lock

LOGFILE=$(sre_log_start "scrub")
sre_write_state "scrub_status" "running" "scrub_started" "$(date +%s)"

# Cancellation support: ajax.php starts us with `setsid`, so our PID is also
# our process-group id. Record it so the webGUI can signal the whole group
# (this wrapper + the running snapraid) to stop, and trap TERM/INT so we can
# report a clean "cancelled" status instead of a generic failure.
CANCELLED=0
trap 'CANCELLED=1' TERM INT
sre_write_state "scrub_pid" "$$"

# Report a user-initiated cancellation and exit.
sre_abort_cancelled() {
    local msg="$1"
    echo "$msg" | tee -a "$LOGFILE"
    sre_write_state "scrub_status" "cancelled" "scrub_finished" "$(date +%s)" "scrub_pid" "" "scrub_progress" ""
    sre_append_history "scrub" "cancelled" "message" "$msg" "log" "$LOGFILE"
    sre_notify "Scrub cancelled" "$msg" "warning"
    exit 1
}

# Self-heal: relink the persisted snapraid binary if it's missing (fast path only)
if ! command -v snapraid >/dev/null 2>&1; then
    bash "${SCRIPT_DIR}/install_snapraid.sh" >> "$LOGFILE" 2>&1
    if ! command -v snapraid >/dev/null 2>&1; then
        MSG="Scrub aborted: snapraid binary not found and could not be auto-relinked. Open the Setup tab to install it."
        echo "$MSG" | tee -a "$LOGFILE"
        sre_write_state "scrub_status" "error" "scrub_last_error" "$MSG" "scrub_finished" "$(date +%s)"
        sre_append_history "scrub" "error" "message" "$MSG" "log" "$LOGFILE"
        sre_notify "Scrub aborted - SnapRAID missing" "$MSG" "alert"
        exit 1
    fi
fi

if [[ ! -f "$SNAPRAID_CONF" ]]; then
    sre_write_state "scrub_status" "error" "scrub_last_error" "No config yet - finish Setup first" "scrub_finished" "$(date +%s)"
    sre_append_history "scrub" "error" "message" "No config yet - finish Setup first" "log" "$LOGFILE"
    exit 1
fi

PERCENT=$(sre_get_setting "SCRUB_PERCENT" "12")   # ~12%/run * ~8 runs covers everything roughly monthly
OLDER_THAN=$(sre_get_setting "SCRUB_OLDER_THAN" "10")

echo "Running snapraid scrub -p ${PERCENT} -o ${OLDER_THAN} ..." >> "$LOGFILE"
sre_write_state "scrub_progress" ""
# Give any in-flight snapraid command (e.g. a Dashboard status-refresh that
# started just before this scrub) time to release its content lock first.
sre_wait_snapraid 120
# --gui (undocumented in 14.9; there is NO short -g) + --log ">>$LOGFILE"
# makes snapraid emit machine-readable run:pos: progress tags into the same
# log; we poll them and publish a live percentage.
snapraid --conf "$SNAPRAID_CONF" scrub -p "$PERCENT" -o "$OLDER_THAN" --gui --log ">>$LOGFILE" >> "$LOGFILE" 2>&1 &
SNAPRAID_PID=$!
sre_poll_progress "$SNAPRAID_PID" "$LOGFILE" "scrub_progress" "scrub_eta"
wait "$SNAPRAID_PID"
SCRUB_RC=$?

# A cancel during the scrub kills snapraid, so SCRUB_RC is a signal code (e.g.
# 143). Report it as a cancellation, not as a scrub failure.
if [[ $CANCELLED -eq 1 ]]; then
    sre_abort_cancelled "Scrub cancelled by user."
fi

# Error count straight from the scrub log's machine-readable summary:* tags
# (soft + io + data). This replaces the old `snapraid status` grep, which
# actually returned the TOTAL file count, not the number of bad files.
ERRORS=$(sre_log_error_count "$LOGFILE")

# Human summary + wall-clock duration for the notification.
SUMMARY=$(sre_log_summary "$LOGFILE" "scrub")
DURATION=$(sre_duration "$(jq -r '.scrub_started // 0' "$STATE_FILE" 2>/dev/null)")

sre_prune_logs

if [[ $SCRUB_RC -eq 0 && $ERRORS -eq 0 ]]; then
    sre_write_state "scrub_status" "ok" "scrub_finished" "$(date +%s)" \
        "scrub_last_bad_files" "0" "scrub_last_log" "$LOGFILE" "scrub_last_error" "" "scrub_pid" "" "scrub_progress" ""
    sre_append_history "scrub" "ok" "bad_files" "0" "log" "$LOGFILE"
    sre_notify "Scrub completed" "${SUMMARY}${DURATION:+, took ${DURATION}}." "normal"
else
    sre_write_state "scrub_status" "issues_found" "scrub_finished" "$(date +%s)" \
        "scrub_last_bad_files" "$ERRORS" "scrub_last_log" "$LOGFILE" "scrub_pid" "" "scrub_progress" ""
    sre_append_history "scrub" "issues" "bad_files" "$ERRORS" "log" "$LOGFILE"
    sre_notify "Scrub found problems" "${SUMMARY}${DURATION:+, took ${DURATION}}. Open the Recover tab in SnapUnraid." "alert"
fi

exit $SCRUB_RC
