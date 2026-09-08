#!/bin/bash
#
# install_cron.sh - (re)write the cron schedule based on settings.ini SCHEDULE
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CRON_FILE="/etc/cron.d/snapunraid"
SCHEDULE=$(sre_get_setting "SCHEDULE" "daily")

# Validate a 5-field cron expression (minute hour day-of-month month day-of-week).
sre_valid_cron() {
    local fields f
    IFS=' ' read -ra fields <<< "$1"
    [[ ${#fields[@]} -eq 5 ]] || return 1
    for f in "${fields[@]}"; do
        [[ "$f" =~ ^[0-9*/,-]+$ ]] || return 1
    done
}

case "$SCHEDULE" in
    daily)
        SYNC_CRON="30 3 * * *"
        SCRUB_CRON="0 4 * * 0"
        ;;
    mwf)
        # Sync Monday/Wednesday/Friday 3:30am; scrub Sunday 4:00am.
        # Note: the Sunday scrub runs ~1.5 days after Friday's sync, so files
        # modified in that window would be flagged against the older parity
        # (same caveat as any schedule whose scrub doesn't follow a sync).
        SYNC_CRON="30 3 * * 1,3,5"
        SCRUB_CRON="0 4 * * 0"
        ;;
    weekly)
        SYNC_CRON="30 3 * * 0"
        SCRUB_CRON="0 4 * * 0"
        ;;
    custom)
        # User-defined cron expressions from the Setup tab. If they're not
        # well-formed 5-field cron, fall back to the daily defaults so the
        # array still gets protected.
        SYNC_CRON=$(sre_get_setting "CUSTOM_SYNC_CRON" "30 3 * * 1,3,5")
        SCRUB_CRON=$(sre_get_setting "CUSTOM_SCRUB_CRON" "0 4 * * 0")
        if ! sre_valid_cron "$SYNC_CRON" || ! sre_valid_cron "$SCRUB_CRON"; then
            echo "WARNING: invalid custom cron expression(s) - falling back to daily sync + weekly scrub."
            SYNC_CRON="30 3 * * *"
            SCRUB_CRON="0 4 * * 0"
        fi
        ;;
    manual)
        # Manual mode: no automatic sync/scrub, but keep the daily health check
        # so proactive alerts (parity stale, disk offline, ...) still fire.
        cat > "$CRON_FILE" <<EOF
# Managed by SnapUnraid - do not edit by hand, use the plugin's Setup tab.
15 3 * * * bash ${SCRIPT_DIR}/alerts.sh check >/dev/null 2>&1
EOF
        /etc/rc.d/rc.cron reload >/dev/null 2>&1 || true
        echo "Manual schedule selected - sync/scrub cron removed, health check kept."
        exit 0
        ;;
    *)
        SYNC_CRON="30 3 * * *"
        SCRUB_CRON="0 4 * * 0"
        ;;
esac

cat > "$CRON_FILE" <<EOF
# Managed by SnapUnraid - do not edit by hand, use the plugin's Setup tab.
15 3 * * * bash ${SCRIPT_DIR}/alerts.sh check >/dev/null 2>&1
${SYNC_CRON} bash ${SCRIPT_DIR}/sync.sh >/dev/null 2>&1
${SCRUB_CRON} bash ${SCRIPT_DIR}/scrub.sh >/dev/null 2>&1
EOF

# Unraid watches /etc/cron.d and reloads automatically, but nudge it just in case
/etc/rc.d/rc.cron reload >/dev/null 2>&1 || true

echo "Installed schedule: sync='${SYNC_CRON}', scrub='${SCRUB_CRON}', alerts='15 3 * * *'"
