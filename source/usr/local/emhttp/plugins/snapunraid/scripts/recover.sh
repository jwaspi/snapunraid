#!/bin/bash
#
# recover.sh - list problem files, run a full check, or fix them
#
# Usage:
#   recover.sh list                 -> JSON array of {disk, path, reason, size}
#   recover.sh check                -> background full array check (errors only)
#   recover.sh fix <disk>           -> attempt to fix all bad files on one disk
#   recover.sh fix-file <path>      -> restore a single file from parity
#   recover.sh fix-all              -> attempt to fix every disk with problems
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ACTION="$1"
ARG="$2"

if [[ ! -f "$SNAPRAID_CONF" ]]; then
    echo '{"error":"not configured"}'
    exit 1
fi

case "$ACTION" in
    list)
        # Parse the most recent check/scrub/sync log for per-file problems via
        # the shared single-pass parser in common.sh. That parser handles the
        # disk-label -> mount mapping (labels like "d6" are declared in
        # snapraid.conf as /mnt/disk4, so /mnt/d6 would be wrong) and preserves
        # paths containing ':'.
        #
        # Deduplication and parsing are done with one awk|sort pass, NOT
        # per-line jq: a scrub with 100k+ error blocks (e.g. every block of
        # deleted files) would spawn a process per line and take minutes. One
        # jq call at the end builds the JSON array.
        state=$(sre_read_state_json)
        log=$(jq -r '.check_last_log // .scrub_last_log // .sync_last_log // ""' <<<"$state" 2>/dev/null)
        if [[ -n "$log" && -f "$log" ]]; then
            sre_parse_problem_tags "$log" | sre_resolve_problem_paths \
                | jq -R -c 'split("\t") | {disk: .[0], path: .[1], reason: .[2], size: (.[3] | tonumber)}' \
                | jq -c -s 'if length == 0 then [] else . end'
        else
            echo "[]"
        fi
        ;;
    check)
        # Full array check (errors only). Runs in the background (setsid) so
        # the webGUI can poll progress and cancel it. Parses the status: tags
        # into check_problems in state.json for the Recover tab.
        if [[ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" != "$$" ]]; then
            exec setsid bash "$0" "$@"
        fi
        sre_lock
        LOGFILE=$(sre_log_start "check")
        sre_write_state "check_status" "running" "check_started" "$(date +%s)"
        CANCELLED=0
        trap 'CANCELLED=1' TERM INT
        sre_write_state "check_pid" "$$"
        sre_abort_cancelled() {
            local msg="$1"
            echo "$msg" | tee -a "$LOGFILE"
            sre_write_state "check_status" "cancelled" "check_finished" "$(date +%s)" "check_pid" "" "check_progress" ""
            sre_notify "Array check cancelled" "$msg" "warning"
            exit 1
        }
        echo "Running snapraid -e check ..." >> "$LOGFILE"
        sre_write_state "check_progress" ""
        # Give any in-flight snapraid command (e.g. a Dashboard status-refresh
        # that started just before this check) time to release its lock first.
        sre_wait_snapraid 120
        # -e = errors only (faster than a full check); --gui (undocumented in
        # 14.9, there is NO short -g) + --log emits run:pos: progress tags we
        # poll for a live percentage.
        snapraid --conf "$SNAPRAID_CONF" -e check --gui --log ">>$LOGFILE" >> "$LOGFILE" 2>&1 &
        SNAPRAID_PID=$!
        sre_poll_progress "$SNAPRAID_PID" "$LOGFILE" "check_progress" "check_eta"
        wait "$SNAPRAID_PID"
        CHECK_RC=$?
        if [[ $CANCELLED -eq 1 ]]; then
            sre_abort_cancelled "Array check cancelled by user."
        fi
        # Parse the check log for per-file results using the same single-pass
        # parser as `list` (one awk|sort + one jq instead of a jq per line).
        PROBLEMS=$(sre_parse_problem_tags "$LOGFILE" | sre_resolve_problem_paths \
            | jq -R -c 'split("\t") | {disk: .[0], path: .[1], reason: .[2], size: (.[3] | tonumber)}' \
            | jq -c -s 'if length == 0 then [] else . end')
        PROBLEMS=${PROBLEMS:-[]}
        sre_prune_logs
        if [[ $CHECK_RC -eq 0 ]]; then
            sre_write_state "check_status" "ok" "check_finished" "$(date +%s)" \
                "check_last_log" "$LOGFILE" "check_pid" "" "check_progress" "" \
                "check_problems" "$PROBLEMS"
            sre_notify "Array check completed" "Full check finished. See the Recover tab for results." "normal"
        else
            sre_write_state "check_status" "error" "check_finished" "$(date +%s)" \
                "check_last_log" "$LOGFILE" "check_pid" "" "check_progress" "" \
                "check_problems" "$PROBLEMS" "check_last_error" "snapraid check exited with code ${CHECK_RC}"
            sre_notify "Array check had issues" "snapraid check exited with code ${CHECK_RC}. See the Recover tab." "alert"
        fi
        exit $CHECK_RC
        ;;
    fix)
        if [[ -z "$ARG" ]]; then
            echo "Usage: recover.sh fix <disk>" >&2
            exit 1
        fi
        sre_lock
        LOGFILE=$(sre_log_start "fix")
        snapraid --conf "$SNAPRAID_CONF" fix -d "$ARG" >> "$LOGFILE" 2>&1
        RC=$?
        if [[ $RC -eq 0 ]]; then
            sre_notify "Recovery completed" "Attempted repair of files on ${ARG}. Check the log for details." "normal"
        else
            sre_notify "Recovery had issues" "snapraid fix on ${ARG} exited with code ${RC}. Some files may be unrecoverable." "alert"
        fi
        echo "{\"exit_code\": $RC, \"log\": \"$LOGFILE\"}"
        exit $RC
        ;;
    fix-file)
        if [[ -z "$ARG" ]]; then
            echo "Usage: recover.sh fix-file <path>" >&2
            exit 1
        fi
        # snapraid's --filter matches paths RELATIVE to the disk mount, so an
        # absolute /mnt/... path never matches ("Nothing to check"). Split the
        # path into its disk label and relative sub-path and pass both.
        SPLIT=$(sre_split_disk_path "$ARG")
        if [[ -z "$SPLIT" ]]; then
            LOGFILE=$(sre_log_start "fix")
            MSG="Could not map '${ARG}' to a configured data disk - it may not be under /mnt/<disk>. Check Setup."
            echo "$MSG" | tee -a "$LOGFILE"
            echo "{\"exit_code\": 1, \"log\": \"$LOGFILE\", \"error\": \"${MSG}\"}"
            exit 1
        fi
        DISK_LABEL="${SPLIT%%$'\t'*}"
        DISK_REL="${SPLIT#*$'\t'}"
        sre_lock
        LOGFILE=$(sre_log_start "fix")
        snapraid --conf "$SNAPRAID_CONF" fix -d "$DISK_LABEL" -f "$DISK_REL" >> "$LOGFILE" 2>&1
        RC=$?
        if [[ $RC -eq 0 ]]; then
            sre_notify "Recovery completed" "Restored '${ARG}' from parity." "normal"
        else
            sre_notify "Recovery had issues" "snapraid fix on '${ARG}' exited with code ${RC}. The file may be unrecoverable." "alert"
        fi
        echo "{\"exit_code\": $RC, \"log\": \"$LOGFILE\"}"
        exit $RC
        ;;
    fix-all)
        sre_lock
        LOGFILE=$(sre_log_start "fix")
        snapraid --conf "$SNAPRAID_CONF" fix >> "$LOGFILE" 2>&1
        RC=$?
        if [[ $RC -eq 0 ]]; then
            sre_notify "Recovery completed" "Attempted repair of all flagged files. Check the log for details." "normal"
        else
            sre_notify "Recovery had issues" "snapraid fix exited with code ${RC}. Some files may be unrecoverable." "alert"
        fi
        echo "{\"exit_code\": $RC, \"log\": \"$LOGFILE\"}"
        exit $RC
        ;;
    *)
        echo "Usage: recover.sh {list|check|fix <disk>|fix-file <path>|fix-all}" >&2
        exit 1
        ;;
esac
