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
        # Parse the most recent check/scrub/sync log for per-file problems.
        # SnapRAID writes machine-readable tags when run with --log:
        #   error_data:<block>:<disk>:<sub>: Data error at position ...   (silent corruption)
        #   error:<block>:<disk>:<sub>: Data error at position ...        (soft error)
        #   status:recoverable:<disk>:<sub>   / status:unrecoverable:<disk>:<sub>  (from check)
        # plus a human-readable line: Data error in file '/mnt/...' at position ...
        # The tag paths are relative to the disk mount, so we rebuild the full
        # path as /mnt/<disk>/<sub>. Pure bash + jq (python3 not guaranteed).
        #
        # Deduplication is done with awk+sort, NOT per-line jq: a scrub with
        # 100k+ error blocks (e.g. every block of deleted files) would spawn a
        # jq process per line and take minutes. One jq call builds the JSON.
        state=$(sre_read_state_json)
        log=$(jq -r '.check_last_log // .scrub_last_log // .sync_last_log // ""' <<<"$state" 2>/dev/null)
        if [[ -n "$log" && -f "$log" ]]; then
            # Extract unique (disk, path, reason) triples from the machine
            # tags. "Open error. No such file or directory." marks a file that
            # was deleted or renamed since the last sync - not damage;
            # restoring it would undo the deletion, the remedy is a sync.
            awk -F':' '
                ($1 == "error" || $1 == "error_data") && $2 ~ /^[0-9]+$/ {
                    r = "checksum mismatch"
                    if ($0 ~ /Open error\. No such file or directory\./) r = "missing"
                    print $3 "\t" $4 "\t" r
                }
                $1 == "status" && ($2 == "recoverable" || $2 == "unrecoverable") {
                    print $3 "\t" $4 "\t" $2
                }
            ' "$log" | sort -u | while IFS=$'\t' read -r disk sub reason; do
                [[ -z "$disk" || -z "$sub" ]] && continue
                path="/mnt/${disk}/${sub#/}"
                size=0
                [[ -f "$path" ]] && size=$(stat -c %s "$path" 2>/dev/null || echo 0)
                printf '%s\t%s\t%s\t%s\n' "$disk" "$path" "$reason" "$size"
            done | jq -R -c 'split("\t") | {disk: .[0], path: .[1], reason: .[2], size: (.[3] | tonumber)}' \
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
        # Parse the check log for per-file results.
        PROBLEMS="[]"
        while IFS= read -r line; do
            if [[ "$line" =~ ^status:(recoverable|unrecoverable):([^:]+):([^:]+)$ ]]; then
                disk="${BASH_REMATCH[2]}"
                path="/mnt/${disk}/${BASH_REMATCH[3]#/}"
                reason="unrecoverable"
                [[ "${BASH_REMATCH[1]}" == "recoverable" ]] && reason="recoverable"
                size=0
                [[ -f "$path" ]] && size=$(stat -c %s "$path" 2>/dev/null || echo 0)
                PROBLEMS=$(jq -c --arg d "$disk" --arg p "$path" --arg r "$reason" --argjson s "${size:-0}" \
                    '. + [{disk:$d,path:$p,reason:$r,size:$s}]' <<<"$PROBLEMS")
            fi
        done < "$LOGFILE"
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
        sre_lock
        LOGFILE=$(sre_log_start "fix")
        snapraid --conf "$SNAPRAID_CONF" fix -f "$ARG" >> "$LOGFILE" 2>&1
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
