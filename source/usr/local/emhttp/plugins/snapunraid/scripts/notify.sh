#!/bin/bash
#
# notify.sh - send a test notification through the plugin's alert pipeline.
#
# Usage: notify.sh test
#
# Fires a notification via sre_notify so the user can confirm Unraid's
# delivery (email / agent / bell) works before relying on the alerts. The
# subject "Test notification" matches no alert toggle, so sre_notify treats
# it as fail-open and always sends.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-test}"

case "$ACTION" in
    test)
        sre_notify "Test notification" "SnapUnraid notifications are working. This is a test." "normal"
        echo '{"ok":true}'
        ;;
    *)
        echo '{"error":"unknown action"}'
        exit 1
        ;;
esac
