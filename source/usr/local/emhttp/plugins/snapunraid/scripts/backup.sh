#!/bin/bash
#
# backup.sh - snapshot and restore the SnapUnraid configuration
#
# Usage:
#   backup.sh backup            -> create a timestamped tarball of snapraid.conf + settings.ini
#   backup.sh list              -> JSON array of {name, date, size}, newest first
#   backup.sh restore <name>    -> restore a backup (overwrites current config)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BACKUP_DIR="${PLUGIN_HOME}/backups"
MAX_BACKUPS=10

case "${1:-}" in
    backup)
        mkdir -p "$BACKUP_DIR"
        NAME="snapunraid-config-$(date +%Y%m%d-%H%M%S).tar.gz"
        # Only back up files that exist; tar without them would error.
        FILES=()
        [[ -f "$SNAPRAID_CONF" ]] && FILES+=("$(basename "$SNAPRAID_CONF")")
        [[ -f "$SETTINGS_FILE" ]] && FILES+=("$(basename "$SETTINGS_FILE")")
        if [[ ${#FILES[@]} -eq 0 ]]; then
            echo '{"ok":false,"error":"nothing to back up - no config or settings yet"}'
            exit 1
        fi
        tar -czf "$BACKUP_DIR/$NAME" -C "$PLUGIN_HOME" "${FILES[@]}" 2>/dev/null
        if [[ $? -ne 0 || ! -f "$BACKUP_DIR/$NAME" ]]; then
            echo '{"ok":false,"error":"backup failed"}'
            exit 1
        fi
        # prune to the newest MAX_BACKUPS
        ls -1t "$BACKUP_DIR"/snapunraid-config-*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f
        echo "{\"ok\":true,\"name\":\"$NAME\"}"
        ;;
    list)
        backups="[]"
        for f in "$BACKUP_DIR"/snapunraid-config-*.tar.gz; do
            [[ -f "$f" ]] || continue
            name=$(basename "$f")
            size=$(stat -c %s "$f" 2>/dev/null || echo 0)
            date=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            backups=$(jq -c --arg n "$name" --argjson s "${size:-0}" --argjson d "${date:-0}" \
                '. + [{name:$n,size:$s,date:$d}]' <<<"$backups")
        done
        # newest first
        echo "$backups" | jq -c 'sort_by(.date) | reverse'
        ;;
    restore)
        NAME="${2:-}"
        # Only allow plain backup filenames - never a path (no traversal).
        if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]]; then
            echo '{"ok":false,"error":"invalid backup name"}'
            exit 1
        fi
        FILE="$BACKUP_DIR/$NAME"
        if [[ ! -f "$FILE" ]]; then
            echo '{"ok":false,"error":"backup not found"}'
            exit 1
        fi
        # Extract to a temp dir and copy only the two known config files, so a
        # tampered tarball can never plant anything else into the config dir.
        TMP=$(mktemp -d)
        tar -xzf "$FILE" -C "$TMP" 2>/dev/null
        RC=$?
        if [[ $RC -eq 0 && -f "$TMP/snapraid.conf" && -f "$TMP/settings.ini" ]]; then
            cp "$TMP/snapraid.conf" "$SNAPRAID_CONF"
            cp "$TMP/settings.ini" "$SETTINGS_FILE"
            echo '{"ok":true}'
        else
            echo '{"ok":false,"error":"restore failed - backup missing config files"}'
        fi
        rm -rf "$TMP"
        ;;
    *)
        echo "Usage: backup.sh {backup|list|restore <name>}" >&2
        exit 1
        ;;
esac
