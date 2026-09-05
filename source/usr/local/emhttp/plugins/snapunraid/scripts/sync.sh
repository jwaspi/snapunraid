#!/bin/bash
#
# sync.sh - run `snapraid sync` with pre-flight safety checks
#
# Usage: sync.sh [--force]
#   --force   skip the deletion/change-threshold confirmation prompt
#             (used when the user explicitly confirms via the webGUI)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Ensure we run as a process-group leader so the webGUI can cancel us by
# signalling the whole group. The webGUI starts us with `setsid`, but cron
# does not - re-exec under setsid when we're not already a group leader.
if [[ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" != "$$" ]]; then
    exec setsid bash "$0" "$@"
fi

FORCE=0
[[ "$1" == "--force" ]] && FORCE=1

sre_lock

LOGFILE=$(sre_log_start "sync")
sre_write_state "sync_status" "running" "sync_started" "$(date +%s)"

# Cancellation support: ajax.php starts us with `setsid`, so our PID is also
# our process-group id. Record it so the webGUI can signal the whole group
# (this wrapper + the running snapraid) to stop, and trap TERM/INT so we can
# report a clean "cancelled" status instead of a generic failure.
CANCELLED=0
trap 'CANCELLED=1' TERM INT
sre_write_state "sync_pid" "$$"

# Report a user-initiated cancellation and exit. Used at each phase boundary
# so a cancel lands as "cancelled" in state/history, not as an error.
sre_abort_cancelled() {
    local msg="$1"
    echo "$msg" | tee -a "$LOGFILE"
    sre_write_state "sync_status" "cancelled" "sync_finished" "$(date +%s)" "sync_pid" "" "sync_progress" ""
    sre_append_history "sync" "cancelled" "message" "$msg" "log" "$LOGFILE"
    sre_notify "Sync cancelled" "$msg" "warning"
    exit 1
}

# ---------------------------------------------------------------------------
# 0) Self-heal: relink the persisted snapraid binary if it's missing
#    (covers the case where the boot-time event hook didn't fire).
#    This is the fast symlink path only - it won't trigger a fresh download
#    from a cron job.
# ---------------------------------------------------------------------------
if ! command -v snapraid >/dev/null 2>&1; then
    bash "${SCRIPT_DIR}/install_snapraid.sh" >> "$LOGFILE" 2>&1
    if ! command -v snapraid >/dev/null 2>&1; then
        MSG="Sync aborted: snapraid binary not found and could not be auto-relinked. Open the Setup tab to install it."
        echo "$MSG" | tee -a "$LOGFILE"
        sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
        sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
        sre_notify "Sync aborted - SnapRAID missing" "$MSG" "alert"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 1) Missing / unmounted disk check
#    A disk that dropped offline looks like "all files deleted" to SnapRAID.
#    Never let a sync proceed if a configured data disk isn't mounted.
# ---------------------------------------------------------------------------
DATA_DISKS=$(sre_get_setting "DATA_DISKS" "")
IFS=',' read -ra DDISKS <<< "$DATA_DISKS"
MISSING=()
for d in "${DDISKS[@]}"; do
    [[ -z "$d" ]] && continue
    if ! mountpoint -q "/mnt/${d}" 2>/dev/null; then
        MISSING+=("$d")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    MSG="Sync aborted: disk(s) not mounted: ${MISSING[*]}. Fix the disk before syncing, or parity will be rewritten as if those files were deleted."
    echo "$MSG" | tee -a "$LOGFILE"
    sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
    sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
    sre_notify "Sync aborted - disk missing" "$MSG" "alert"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1b) Parity disk check
#     SnapRAID needs parity as a file on a mounted filesystem. A raw device
#     path (e.g. /dev/sdg) is never valid, and an unmounted parity disk would
#     make the sync fail (or worse, write parity somewhere unexpected).
# ---------------------------------------------------------------------------
PARITY_PATH=$(sre_get_setting "PARITY_PATH" "")
if [[ "$PARITY_PATH" == /dev/* ]]; then
    MSG="Sync aborted: parity path is a raw device, which SnapRAID doesn't support. Format the disk and add it as a pool, then update Setup."
    echo "$MSG" | tee -a "$LOGFILE"
    sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
    sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
    sre_notify "Sync aborted - raw parity device" "$MSG" "alert"
    exit 1
fi
if ! mountpoint -q "/mnt/${PARITY_PATH}" 2>/dev/null; then
    MSG="Sync aborted: parity disk '${PARITY_PATH}' is not mounted. Start the pool/disk before syncing."
    echo "$MSG" | tee -a "$LOGFILE"
    sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
    sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
    sre_notify "Sync aborted - parity disk missing" "$MSG" "alert"
    exit 1
fi

# Optional second parity disk: same rules as the first, plus it must be a
# different disk (SnapRAID rejects parity and parity-2 on one device).
PARITY2_PATH=$(sre_get_setting "PARITY2_PATH" "")
if [[ -n "$PARITY2_PATH" ]]; then
    if [[ "$PARITY2_PATH" == /dev/* ]]; then
        MSG="Sync aborted: second parity path is a raw device, which SnapRAID doesn't support. Format the disk and add it as a pool, then update Setup."
        echo "$MSG" | tee -a "$LOGFILE"
        sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
        sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
        sre_notify "Sync aborted - raw second parity device" "$MSG" "alert"
        exit 1
    fi
    if [[ "$PARITY2_PATH" == "$PARITY_PATH" ]]; then
        MSG="Sync aborted: the second parity disk must be different from the first parity disk."
        echo "$MSG" | tee -a "$LOGFILE"
        sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
        sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
        sre_notify "Sync aborted - same parity disk" "$MSG" "alert"
        exit 1
    fi
    if ! mountpoint -q "/mnt/${PARITY2_PATH}" 2>/dev/null; then
        MSG="Sync aborted: second parity disk '${PARITY2_PATH}' is not mounted. Start the pool/disk before syncing."
        echo "$MSG" | tee -a "$LOGFILE"
        sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
        sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
        sre_notify "Sync aborted - second parity disk missing" "$MSG" "alert"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 1c) Parity disk free-space check
#     A sync rewrites parity to match the largest data disk, so each parity
#     disk must have room for that growth. If it doesn't, the sync fails
#     partway through and can leave parity in a bad state. Estimate the
#     needed space up front and abort with a clear message instead.
# ---------------------------------------------------------------------------
MAX_USED_KB=0
for d in "${DDISKS[@]}"; do
    [[ -z "$d" ]] && continue
    USED=$(df -Pk "/mnt/${d}" 2>/dev/null | awk 'NR==2 {print $3}')
    [[ -n "$USED" && "$USED" -gt "$MAX_USED_KB" ]] && MAX_USED_KB=$USED
done
# 1 GiB safety margin so the sync isn't starved by concurrent writes.
MARGIN_KB=$((1024 * 1024))

# Abort if one parity disk lacks room. Needed = largest data disk's used
# space minus what that parity file already holds.
sre_check_parity_space() {
    local p="$1" f="$2"
    local free_kb size_kb needed_kb
    free_kb=$(df -Pk "/mnt/${p}" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ -z "$free_kb" ]] && return 0   # df failed; skip the check
    size_kb=0
    [[ -f "/mnt/${p}/${f}" ]] && size_kb=$(( $(stat -c %s "/mnt/${p}/${f}" 2>/dev/null) / 1024 ))
    needed_kb=$((MAX_USED_KB - size_kb))
    [[ $needed_kb -lt 0 ]] && needed_kb=0
    if [[ $((needed_kb + MARGIN_KB)) -gt "$free_kb" ]]; then
        MSG="Sync aborted: not enough free space on parity disk '${p}' (${free_kb} KB free, need ~$((needed_kb + MARGIN_KB)) KB). Free up space or use a larger parity disk."
        echo "$MSG" | tee -a "$LOGFILE"
        sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
        sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
        sre_notify "Sync aborted - parity disk full" "$MSG" "alert"
        exit 1
    fi
}
sre_check_parity_space "$PARITY_PATH" "snapraid.parity"
[[ -n "$PARITY2_PATH" ]] && sre_check_parity_space "$PARITY2_PATH" "snapraid.parity-2"

# A cancel requested during the (fast) pre-flight checks lands here.
if [[ $CANCELLED -eq 1 ]]; then
    sre_abort_cancelled "Sync cancelled by user."
fi

# ---------------------------------------------------------------------------
# 2) Regenerate config (keeps it in sync with current settings)
# ---------------------------------------------------------------------------
if ! bash "${SCRIPT_DIR}/genconfig.sh" >>"$LOGFILE" 2>&1; then
    sre_write_state "sync_status" "error" "sync_last_error" "Failed to write snapraid.conf" "sync_finished" "$(date +%s)"
    sre_append_history "sync" "error" "message" "Failed to write snapraid.conf" "log" "$LOGFILE"
    sre_notify "Sync aborted - config error" "Could not generate snapraid.conf. Check Setup." "alert"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3) Dry-run diff to evaluate the size of the change before committing
#    `snapraid diff` exit codes: 0 = no changes, 2 = changes found, other = error
# ---------------------------------------------------------------------------
DIFF_OUT=$(snapraid --conf "$SNAPRAID_CONF" diff 2>&1)
DIFF_RC=$?
echo "$DIFF_OUT" >> "$LOGFILE"

# A cancel during the diff kills snapraid, so DIFF_RC would be a signal code
# (e.g. 143). Report it as a cancellation, not as a diff failure.
if [[ $CANCELLED -eq 1 ]]; then
    sre_abort_cancelled "Sync cancelled by user."
fi

# `snapraid diff` exit codes: 0 = no changes, 2 = changes found, other = error.
# A failed diff must never be treated as "no changes" - abort so the user can
# investigate instead of syncing blindly.
if [[ $DIFF_RC -ne 0 && $DIFF_RC -ne 2 ]]; then
    MSG="Sync aborted: 'snapraid diff' failed (exit code ${DIFF_RC}). Check the log."
    echo "$MSG" | tee -a "$LOGFILE"
    sre_write_state "sync_status" "error" "sync_last_error" "$MSG" "sync_finished" "$(date +%s)"
    sre_append_history "sync" "error" "message" "$MSG" "log" "$LOGFILE"
    sre_notify "Sync aborted - diff error" "$MSG" "alert"
    exit 1
fi

# NOTE: `snapraid diff` prints its per-kind counts with leading whitespace,
# e.g. "     12 added" / "      5 removed" / " 2000 updated". Anchor the
# match on the word and allow any leading space so the counts are reliable.
ADDED=$(echo "$DIFF_OUT" | grep -oE '[[:space:]]*[0-9]+ added' | grep -oE '[0-9]+' | head -1)
REMOVED=$(echo "$DIFF_OUT" | grep -oE '[[:space:]]*[0-9]+ removed' | grep -oE '[0-9]+' | head -1)
UPDATED=$(echo "$DIFF_OUT" | grep -oE '[[:space:]]*[0-9]+ updated' | grep -oE '[0-9]+' | head -1)
ADDED=${ADDED:-0}; REMOVED=${REMOVED:-0}; UPDATED=${UPDATED:-0}

THRESHOLD_COUNT=$(sre_get_setting "DELETE_THRESHOLD_COUNT" "50")
CHANGED=$((REMOVED + UPDATED))

if [[ $FORCE -eq 0 && $CHANGED -gt $THRESHOLD_COUNT ]]; then
    MSG="Sync paused: ${REMOVED} removed / ${UPDATED} updated files exceeds your safety threshold of ${THRESHOLD_COUNT}. This usually means a disk emptied unexpectedly or a large deletion happened. Review and confirm in the webGUI to proceed."
    echo "$MSG" | tee -a "$LOGFILE"
    sre_write_state "sync_status" "needs_confirmation" \
        "sync_pending_added" "$ADDED" "sync_pending_removed" "$REMOVED" "sync_pending_updated" "$UPDATED" \
        "sync_pending_log" "$LOGFILE" "sync_finished" "$(date +%s)" "sync_pid" "" "sync_progress" ""
    sre_append_history "sync" "paused" "message" "$MSG" "added" "$ADDED" "removed" "$REMOVED" "updated" "$UPDATED" "log" "$LOGFILE"
    sre_notify "Sync needs confirmation" "$MSG" "warning"
    exit 2
fi

# ---------------------------------------------------------------------------
# 4) Run the actual sync
# ---------------------------------------------------------------------------
echo "Running snapraid sync ..." >> "$LOGFILE"
sre_write_state "sync_progress" ""
# --gui (undocumented in 14.9; there is NO short -g) + --log ">>$LOGFILE"
# makes snapraid emit machine-readable run:pos: progress tags into the same
# log; we poll them and publish a live percentage to the Dashboard. Run in
# the background so the poll loop can watch the log.
snapraid --conf "$SNAPRAID_CONF" sync --gui --log ">>$LOGFILE" >> "$LOGFILE" 2>&1 &
SNAPRAID_PID=$!
sre_poll_progress "$SNAPRAID_PID" "$LOGFILE" "sync_progress" "sync_eta"
wait "$SNAPRAID_PID"
SYNC_RC=$?

# A cancel during the sync kills snapraid, so SYNC_RC is a signal code (e.g.
# 143). Report it as a cancellation, not as a sync failure.
if [[ $CANCELLED -eq 1 ]]; then
    sre_abort_cancelled "Sync cancelled by user."
fi

sre_prune_logs

# Pull the actual run summary (added/removed/updated/errors) from the log's
# machine-readable summary:* tags, plus the wall-clock duration.
SUMMARY=$(sre_log_summary "$LOGFILE" "sync")
DURATION=$(sre_duration "$(jq -r '.sync_started // 0' "$STATE_FILE" 2>/dev/null)")

if [[ $SYNC_RC -eq 0 ]]; then
    sre_write_state "sync_status" "ok" "sync_finished" "$(date +%s)" \
        "sync_last_added" "$ADDED" "sync_last_removed" "$REMOVED" "sync_last_updated" "$UPDATED" \
        "sync_last_log" "$LOGFILE" "sync_last_error" "" "sync_pid" "" "sync_progress" ""
    sre_append_history "sync" "ok" "added" "$ADDED" "removed" "$REMOVED" "updated" "$UPDATED" "log" "$LOGFILE"
    sre_notify "Sync completed" "${SUMMARY}${DURATION:+, took ${DURATION}}." "normal"
else
    sre_write_state "sync_status" "error" "sync_finished" "$(date +%s)" "sync_last_log" "$LOGFILE" \
        "sync_last_error" "snapraid sync exited with code ${SYNC_RC}, see log" "sync_pid" "" "sync_progress" ""
    sre_append_history "sync" "error" "message" "snapraid sync exited with code ${SYNC_RC}" "log" "$LOGFILE"
    sre_notify "Sync failed" "snapraid sync exited with code ${SYNC_RC}. ${SUMMARY}${DURATION:+, took ${DURATION}}. Check the log in the plugin's Dashboard tab." "alert"
fi

exit $SYNC_RC
