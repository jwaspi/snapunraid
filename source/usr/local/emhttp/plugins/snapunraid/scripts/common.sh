#!/bin/bash
#
# common.sh - shared helpers for SnapUnraid
#
# Sourced by sync.sh, scrub.sh, status.sh, genconfig.sh
#

PLUGIN_NAME="snapunraid"
PLUGIN_HOME="/boot/config/plugins/${PLUGIN_NAME}"
PLUGIN_VAR="/var/local/${PLUGIN_NAME}"        # runtime state (not persisted across reboot, rebuilt on start)
# Paths can be overridden via env (SRE_*) for testing without touching the
# real plugin files.
SETTINGS_FILE="${SRE_SETTINGS_FILE:-${PLUGIN_HOME}/settings.ini}"
SNAPRAID_CONF="${SRE_SNAPRAID_CONF:-${PLUGIN_HOME}/snapraid.conf}"
STATE_FILE="${SRE_STATE_FILE:-${PLUGIN_VAR}/state.json}"
LOG_DIR="${SRE_LOG_DIR:-${PLUGIN_VAR}/logs}"
HISTORY_FILE="${SRE_HISTORY_FILE:-${PLUGIN_HOME}/history.jsonl}"   # persistent append-only run history (not wiped on uninstall)
LOCK_FILE="/var/lock/${PLUGIN_NAME}.lock"

mkdir -p "$PLUGIN_HOME" "$PLUGIN_VAR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# Settings are stored as simple KEY=VALUE pairs in settings.ini
# ---------------------------------------------------------------------------
sre_get_setting() {
    local key="$1"
    local default="$2"
    if [[ -f "$SETTINGS_FILE" ]]; then
        local val
        val=$(grep -E "^${key}=" "$SETTINGS_FILE" | tail -1 | cut -d'=' -f2-)
        if [[ -n "$val" ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

sre_set_setting() {
    local key="$1"
    local value="$2"
    touch "$SETTINGS_FILE"
    if grep -qE "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$SETTINGS_FILE"
    else
        echo "${key}=${value}" >> "$SETTINGS_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Logging - human readable log per run, kept for the Dashboard history list
# ---------------------------------------------------------------------------
sre_log_start() {
    local kind="$1"   # sync | scrub
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    echo "${LOG_DIR}/${kind}-${ts}.log"
}

sre_prune_logs() {
    # keep the most recent 30 logs of each kind
    ls -1t "${LOG_DIR}"/sync-*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
    ls -1t "${LOG_DIR}"/scrub-*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
}

# ---------------------------------------------------------------------------
# State JSON - single source of truth the webGUI page polls for the Dashboard
# ---------------------------------------------------------------------------
sre_write_state() {
    # sre_write_state <field> <value> ... written as flat JSON, merges over existing.
    # Implemented with jq (ships with Unraid; python3 is not guaranteed present).
    #
    # Type coercion: values that are valid JSON scalars (true/false/number)
    # are stored typed; everything else stored as a string. This mirrors the
    # original python3 behaviour the webGUI relies on.
    local state_file="$STATE_FILE"
    local temp_file="${STATE_FILE}.tmp"
    mkdir -p "$(dirname "$state_file")"

    local jq_flags=()
    local filter=''
    local k v
    local i=0
    while [[ $# -ge 2 ]]; do
        k="$1"; v="$2"; shift 2
        if [[ "$v" == "true" || "$v" == "false" ]] || [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
            jq_flags+=(--argjson "v$i" "$v")
        else
            jq_flags+=(--arg "v$i" "$v")
        fi
        if [[ -z "$filter" ]]; then
            filter=".[\"$k\"] = \$v$i"
        else
            filter+=" | .[\"$k\"] = \$v$i"
        fi
        i=$((i+1))
    done

    if [[ -f "$state_file" ]]; then
        jq -c "$filter" "$state_file" "${jq_flags[@]}" > "$temp_file" 2>/dev/null \
            && mv "$temp_file" "$state_file" \
            || rm -f "$temp_file"
    else
        echo '{}' | jq -c "$filter" "${jq_flags[@]}" > "$temp_file" 2>/dev/null \
            && mv "$temp_file" "$state_file" \
            || rm -f "$temp_file"
    fi
}

sre_read_state_json() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

# ---------------------------------------------------------------------------
# Live progress polling - watch a snapraid log while it runs and publish the
# percentage (two decimals where possible) + ETA to state.json.
#
# sre_poll_progress <pid> <logfile> <progress_key> <eta_key>
#   <pid>          snapraid process to wait on (loop exits when it dies)
#   <logfile>      the run's log (snapraid --log ">>$LOGFILE")
#   <progress_key> state.json key for the percentage (e.g. sync_progress)
#   <eta_key>      state.json key for the ETA (e.g. sync_eta)
#
# Percentage strategy - snapraid only prints an integer percentage, so we
# reconstruct the fraction ourselves to give the Dashboard smooth decimals:
#
#   - With --gui the log carries the machine-readable tag
#       run:pos:<blockpos>:<countpos>:<countsize>:<out_perc>:<eta_sec>:...
#     out_perc = floor(countpos*100/countmax) where countmax is the total
#     number of unit-blocks to process (never printed). But countpos*100/out_perc
#     is an UPPER bound on countmax that is tight right after each integer-
#     percent tick, so the running MINIMUM of that bound converges to the true
#     countmax within ~0.01%. precise% = countpos*100/countmax_est.
#
#   - Fallback (no --gui): parse the human-readable bar ("42%, 1234 MB, ... ETA")
#     and interpolate within the current integer band using the MB counter and
#     the width (in MB) of the last completed band. countsize grows smoothly
#     while the percent only ticks at band boundaries, so this yields a smooth
#     two-decimal estimate even when snapraid prints an integer.
#
#   - Before any calibration data exists (start of a run) fall back to the
#     raw integer percent.
#
# ETA is normalized to HH:MM.
# ---------------------------------------------------------------------------
sre_poll_progress() {
    local pid="$1" logfile="$2" progress_key="$3" eta_key="$4"
    local last_pct="" last_eta="" pct eta_str eta_sec tagline tag
    local countpos="" pct_int="" cme="" est=""          # run:pos state
    local bar="" fb_pct="" fb_mb="" fb_start_mb="" fb_width=""   # fallback state

    # If snapraid wasn't run with --gui there are no run:pos tags. Seed the band
    # interpolation from the log history so a poller that starts mid-band (a
    # run already in progress) can show decimals immediately: replay every bar
    # line to find the start-MB of the current integer band and the width (in
    # MB) of the last completed band.
    if ! grep -q 'run:pos:' "$logfile" 2>/dev/null; then
        read -r fb_pct fb_start_mb fb_width <<< "$(grep -oE '[0-9]+%, [0-9]+ MB' "$logfile" 2>/dev/null | awk '
            { if (match($0, /^[0-9]+/))        p = substr($0, RSTART, RLENGTH)+0; else next;
              if (match($0, /[0-9]+ MB/))      m  = substr($0, RSTART, RLENGTH)+0; else next;
              if (!first && p == last)         next;
              if (!first) { w = m - start; if (w > 0) width = w; }
              start = m; last = p; first = 0 }
            END { print last "", start "", width "" }')"
        [[ -z "$fb_width" || "$fb_width" -eq 0 ]] && fb_width=""   # no completed band yet
    fi

    while kill -0 "$pid" 2>/dev/null; do
        pct=""
        tagline=$(grep 'run:pos:' "$logfile" 2>/dev/null | tail -1)
        if [[ -n "$tagline" ]]; then
            # Strip any prefix the log might add; keep run:pos: and numbers.
            tag=$(sed -n 's/.*\(run:pos:[0-9:]*\).*/\1/p' <<<"$tagline")
            IFS=: read -ra F <<< "$tag"
            countpos="${F[3]}"
            pct_int="${F[5]}"
            eta_sec="${F[6]}"
            if [[ -n "$countpos" && -n "$pct_int" ]]; then
                # Calibrate countmax from the tightest upper bound seen so far.
                if [[ "$pct_int" -ge 1 ]]; then
                    est=$(( countpos * 100 / pct_int ))
                    if [[ -z "$cme" || "$est" -lt "$cme" ]]; then
                        cme="$est"
                    fi
                fi
                if [[ -n "$cme" && "$countpos" -gt 0 ]]; then
                    pct=$(awk -v c="$countpos" -v m="$cme" 'BEGIN{printf "%.2f", c*100.0/m}')
                else
                    pct="$pct_int"
                fi
            fi
        else
            bar=$(grep -oE '[0-9]+%, [0-9]+ MB' "$logfile" 2>/dev/null | tail -1)
            if [[ -n "$bar" ]]; then
                pct_int=$(grep -oE '^[0-9]+' <<<"$bar")
                fb_mb=$(grep -oE '[0-9]+ MB' <<<"$bar" | grep -oE '^[0-9]+')
                if [[ -n "$pct_int" && -n "$fb_mb" && "$fb_mb" -gt 0 ]]; then
                    if [[ -n "$fb_pct" && "$pct_int" != "$fb_pct" ]]; then
                        # Integer tick: band just completed; reuse its MB width
                        # to interpolate later bands.
                        if [[ -n "$fb_start_mb" ]]; then
                            est=$(( fb_mb - fb_start_mb ))
                            [[ "$est" -gt 0 ]] && fb_width="$est"
                        fi
                        fb_start_mb="$fb_mb"
                    elif [[ -z "$fb_pct" ]]; then
                        fb_start_mb="$fb_mb"
                    fi
                    fb_pct="$pct_int"
                    if [[ "$pct_int" -eq 0 ]]; then
                        pct="0"
                    elif [[ -n "$fb_width" && -n "$fb_start_mb" ]]; then
                        # fraction is 0..~1 within the band; cap just under 1
                        # so display shows p.99 max until the next integer tick.
                        pct=$(awk -v p="$pct_int" -v m="$fb_mb" -v s="$fb_start_mb" -v w="$fb_width" \
                            'BEGIN{ f=(m-s)/w; if(f<0)f=0; if(f>=1)f=0.999; printf "%.2f", p+f }')
                    else
                        pct="$pct_int"
                    fi
                fi
            fi
        fi

        eta_str=""
        if [[ -n "$tag" ]]; then
            # run:pos field 6 is the ETA in seconds -> HH:MM.
            if [[ -n "$eta_sec" && "$eta_sec" != "0" ]]; then
                eta_str=$(printf "%d:%02d" $((eta_sec / 3600)) $(((eta_sec % 3600) / 60)))
            fi
        else
            # Fallback: human-readable progress bar ETA.
            eta_str=$(grep -oE '[0-9]+:[0-9]{2} ETA' "$logfile" 2>/dev/null | tail -1 | grep -oE '^[0-9]+:[0-9]{2}')
        fi
        if [[ -n "$pct" && "$pct" != "$last_pct" ]]; then
            last_pct="$pct"
            sre_write_state "$progress_key" "$pct"
        fi
        if [[ -n "$eta_str" && "$eta_str" != "$last_eta" ]]; then
            last_eta="$eta_str"
            sre_write_state "$eta_key" "$eta_str"
        fi
        sleep 2
    done
}

# ---------------------------------------------------------------------------
# History - append a completed run to the persistent history file.
# Each record is one JSON object per line (JSONL). Oldest entries are pruned to
# HISTORY_MAX. Used by the History tab.
# ---------------------------------------------------------------------------
HISTORY_MAX=100

sre_append_history() {
    # sre_append_history type status [field value]...
    # Builds and appends a record with a timestamp; prunes to newest HISTORY_MAX.
    local type="$1"; local status="$2"; shift 2
    local ts json rec

    ts=$(date +%s)
    json=$(jq -cn --arg type "$type" --arg status "$status" --argjson ts "$ts" \
        '{ts:$ts, type:$type, status:$status}' 2>/dev/null)
    [[ -z "$json" ]] && return 1

    # merge extra field/value pairs (strings safely)
    while [[ $# -ge 2 ]]; do
        json=$(jq -cn --argjson o "$json" --arg k "$1" --arg v "$2" \
            '$o + {($k):$v}' 2>/dev/null)
        shift 2
        [[ -z "$json" ]] && return 1
    done

    mkdir -p "$(dirname "$HISTORY_FILE")"
    echo "$json" >> "$HISTORY_FILE"

    # prune to newest HISTORY_MAX lines
    local tmp; tmp=$(mktemp)
    tail -n "$HISTORY_MAX" "$HISTORY_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$HISTORY_FILE"
    rm -f "$tmp"
}

sre_read_history() {
    # Output JSON array of history records, newest first.
    if [[ ! -f "$HISTORY_FILE" ]]; then
        jq -cn '[ ]' 2>/dev/null
        return
    fi
    # each line is already JSON; wrap in an array and reverse to newest-first
    jq -cn '[inputs] | reverse' "$HISTORY_FILE" 2>/dev/null || jq -cn '[ ]' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Run summaries - parse the machine-readable summary:* tags snapraid writes at
# the end of a run (with --log) into a one-line human summary for notifications.
#
#   summary:added:N / summary:removed:N / summary:updated:N   (scan phase)
#   summary:error_soft:N / summary:error_io:N / summary:error_data:N
# ---------------------------------------------------------------------------
sre_log_error_count() {
    # sre_log_error_count <logfile> -> total soft+io+data errors
    local logfile="$1"
    local soft io data
    soft=$(grep -oE 'summary:error_soft:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    io=$(grep -oE 'summary:error_io:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    data=$(grep -oE 'summary:error_data:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    echo $(( ${soft:-0} + ${io:-0} + ${data:-0} ))
}

sre_log_summary() {
    # sre_log_summary <logfile> <kind>  (kind = sync | scrub)
    local logfile="$1" kind="$2"
    local added removed updated soft io data errors
    added=$(grep -oE 'summary:added:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    removed=$(grep -oE 'summary:removed:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    updated=$(grep -oE 'summary:updated:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    soft=$(grep -oE 'summary:error_soft:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    io=$(grep -oE 'summary:error_io:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    data=$(grep -oE 'summary:error_data:[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    added=${added:-0}; removed=${removed:-0}; updated=${updated:-0}
    soft=${soft:-0}; io=${io:-0}; data=${data:-0}
    errors=$((soft + io + data))
    if [[ "$kind" == "sync" ]]; then
        echo "${added} added, ${removed} removed, ${updated} updated, ${errors} error(s)"
    elif [[ $errors -eq 0 ]]; then
        echo "No errors"
    else
        echo "${errors} error(s) (${soft} soft, ${io} io, ${data} data)"
    fi
}

sre_duration() {
    # sre_duration <start_epoch> [end_epoch] -> "Hh MMm" (e.g. "2h 14m", "45m")
    # Empty string if start is missing/zero.
    local start="$1" end="${2:-$(date +%s)}"
    [[ -z "$start" || "$start" -eq 0 ]] && echo "" && return
    local secs=$(( end - start ))
    [[ $secs -lt 0 ]] && secs=0
    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
    if [[ $h -gt 0 ]]; then
        echo "${h}h ${m}m"
    else
        echo "${m}m"
    fi
}

# ---------------------------------------------------------------------------
# Alerts - toggleable Unraid notifications (see the Alerts tab).
# ---------------------------------------------------------------------------
sre_alert_enabled() {
    # sre_alert_enabled <key> <default>  -> true if the alert setting is "1"
    local key="$1" default="$2"
    [[ "$(sre_get_setting "$key" "$default")" == "1" ]]
}

sre_alert_once() {
    # sre_alert_once <state_key> <subject> <description> <level> [cooldown_hours]
    # Fire a notification at most once per cooldown (default 24h) while the
    # condition persists, so proactive health checks don't spam on every
    # status refresh. Tracks the last-sent epoch in state.json.
    local key="$1" subject="$2" desc="$3" level="$4" cooldown="${5:-24}"
    local now last
    now=$(date +%s)
    last=$(jq -r ".${key} // 0" "$STATE_FILE" 2>/dev/null)
    [[ -z "$last" ]] && last=0
    if [[ $(( now - last )) -ge $(( cooldown * 3600 )) ]]; then
        sre_notify "$subject" "$desc" "$level"
        sre_write_state "$key" "$now"
    fi
}

# ---------------------------------------------------------------------------
# Notifications - reuse Unraid's native notification system. Each subject maps
# to an alert toggle in settings.ini (Alerts tab); if that toggle is off the
# notification is suppressed. Unknown subjects always notify (fail-open), so a
# new notification can never be silently lost.
# ---------------------------------------------------------------------------
sre_notify() {
    local subject="$1"
    local description="$2"
    local level="$3"   # normal | warning | alert

    # Map subject -> alert setting key. Defaults: problems ON, routine OFF.
    local key="" default="1"
    case "$subject" in
        "Sync completed"*)             key="ALERT_SYNC_OK"       default="0" ;;
        "Sync failed"*|"Sync aborted"*) key="ALERT_SYNC_ERROR"    ;;
        "Sync needs confirmation"*)     key="ALERT_SYNC_CONFIRM"  ;;
        "Scrub completed"*)             key="ALERT_SCRUB_OK"      default="0" ;;
        "Scrub found problems"*|"Scrub aborted"*) key="ALERT_SCRUB_ISSUES" ;;
        "Recovery completed"*)          key="ALERT_RECOVER_OK"    default="0" ;;
        "Recovery had issues"*)        key="ALERT_RECOVER_ERROR" ;;
        "Array check completed"*)       key="ALERT_SCRUB_OK"      default="0" ;;
        "Array check had issues"*)     key="ALERT_SCRUB_ISSUES"  ;;
        *cancelled*)                   key="ALERT_CANCELLED"     default="0" ;;
    esac
    if [[ -n "$key" ]]; then
        sre_alert_enabled "$key" "$default" || return 0
    fi

    # SRE_NOTIFY_BIN override is for testing only; production uses Unraid's
    # native notification dispatcher.
    ${SRE_NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify} \
        -e "SnapUnraid" \
        -s "$subject" \
        -d "$description" \
        -i "$level" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Locking - prevent overlapping sync/scrub runs
# ---------------------------------------------------------------------------
sre_lock() {
    exec 200>"$LOCK_FILE"
    flock -n 200 || { echo "Another SnapUnraid operation is already running."; exit 1; }
}
