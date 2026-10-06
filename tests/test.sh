#!/bin/bash
#
# test.sh - offline unit tests for SnapUnraid's shell helpers.
#
# These do NOT touch the real plugin files, /boot, or snapraid: common.sh
# supports SRE_* environment overrides for exactly this purpose, and every
# fixture lives in a throwaway temp dir.
#
# Usage: bash tests/test.sh            (from anywhere)
#        bash tests/run.sh
#
# The suite deliberately covers the areas that have regressed before: disk
# label -> mount mapping, problem-tag parsing, error/block counting, the
# empty-vs-unset setting distinction, and the settings writer's handling of
# shell/sed metacharacters.
#
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../source/usr/local/emhttp/plugins/snapunraid/scripts"

pass=0
fail=0

ok()   { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; }
eq()   { # eq <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
has()  { # has <desc> <file> <pattern>
    if grep -qE "$3" "$2"; then ok "$1"; else bad "$1" "pattern [$3] not in $2"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Point every override at the throwaway dir so nothing escapes the sandbox.
export SRE_PLUGIN_HOME="$TMP/flash"
export SRE_PLUGIN_VAR="$TMP/var"
export SRE_LOCK_FILE="$TMP/lock"
mkdir -p "$SRE_PLUGIN_HOME" "$SRE_PLUGIN_VAR"

# ---------------------------------------------------------------------------
# Fixture: a snapraid.conf with two data disks whose LABELS (d1/d6) differ from
# their mount names (disk1/disk4) - the exact mismatch that caused the recover
# path bug.
# ---------------------------------------------------------------------------
CONF="$TMP/flash/snapraid.conf"
cat > "$CONF" <<'EOF'
parity /mnt/parity/snapraid.parity
content /mnt/disk1/.snapraid/snapraid.content
data d1 /mnt/disk1/
data d6 /mnt/disk4/
exclude *.tmp
blocksize 256
EOF
export SRE_SNAPRAID_CONF="$CONF"

# ---------------------------------------------------------------------------
# sre_disk_mount / sre_split_disk_path
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$SCRIPTS/common.sh"

eq "sre_disk_mount resolves d6 -> /mnt/disk4" "/mnt/disk4" "$(sre_disk_mount d6)"
eq "sre_disk_mount resolves d1 -> /mnt/disk1" "/mnt/disk1" "$(sre_disk_mount d1)"
eq "sre_disk_mount falls back to /mnt/<label>" "/mnt/dX" "$(sre_disk_mount dX)"
eq "sre_split_disk_path label" "d6" "$(sre_split_disk_path /mnt/disk4/dir/file.bin | cut -f1)"
eq "sre_split_disk_path sub"  "dir/file.bin" "$(sre_split_disk_path /mnt/disk4/dir/file.bin | cut -f2)"
if sre_split_disk_path /mnt/other/file >/dev/null 2>&1; then
    bad "sre_split_disk_path rejects unmapped path"
else
    ok "sre_split_disk_path rejects unmapped path"
fi

# ---------------------------------------------------------------------------
# sre_get_setting vs sre_get_setting_raw. The generic reader treats an empty
# value as unset (scalar defaults); the raw reader must honor an explicit empty
# value so "no excludes" is representable.
# ---------------------------------------------------------------------------
SET="$TMP/flash/settings.ini"
printf 'EXCLUDES=\nTHRESHOLD=\nPARITY_PATH=disk1\n' > "$SET"
eq "sre_get_setting returns default for empty value" "DEF" "$(sre_get_setting EXCLUDES DEF)"
eq "sre_get_setting_raw honors explicit empty" "" "$(sre_get_setting_raw EXCLUDES DEF)"
eq "sre_get_setting_raw returns default when key absent" "DEF" "$(sre_get_setting_raw NOPE DEF)"
eq "sre_get_setting_raw reads a present value" "disk1" "$(sre_get_setting_raw PARITY_PATH DEF)"

# ---------------------------------------------------------------------------
# sre_set_setting must not be corrupted by sed metacharacters (& | \) in the
# value - the original bug rewrote settings.ini silently.
# ---------------------------------------------------------------------------
sre_set_setting "EXCLUDES" 'a&b|c*d'
eq "sre_set_setting preserves & and |" 'a&b|c*d' "$(sre_get_setting_raw EXCLUDES '')"
sre_set_setting "EXCLUDES" 'again'
eq "sre_set_setting replaces an existing key" 'again' "$(sre_get_setting_raw EXCLUDES '')"
eq "sre_set_setting leaves other keys intact" 'disk1' "$(sre_get_setting_raw PARITY_PATH '')"
eq "sre_set_setting has one EXCLUDES line" "1" "$(grep -c '^EXCLUDES=' "$SET")"

# ---------------------------------------------------------------------------
# sre_valid_cron
# ---------------------------------------------------------------------------
for good in "30 3 * * 1,3,5" "0 4 * * 0" "*/5 * * * *" "0 0 1 1 0"; do
    if sre_valid_cron "$good"; then ok "sre_valid_cron accepts '$good'"; else bad "sre_valid_cron accepts '$good'"; fi
done
for badcron in "30 3 * *" "30 3 * * 1,3,5 extra" "" "a b c d e"; do
    if sre_valid_cron "$badcron"; then bad "sre_valid_cron rejects '$badcron'"; else ok "sre_valid_cron rejects '$badcron'"; fi
done

# ---------------------------------------------------------------------------
# sre_parse_problem_tags - checksum, silent corruption and missing-file tags,
# with a ':' inside a path preserved.
# ---------------------------------------------------------------------------
LOG="$TMP/check.log"
cat > "$LOG" <<'EOF'
error:100:d6:movies/My Film.mkv: Data error at offset 512
error:101:d6:movies/My Film.mkv: Data error at offset 1024
error_data:200:d1:backup/a:b.bin: Unrecoverable error
error:300:d1:gone/file.txt: Open error. No such file or directory.
status:recoverable:d6:movies/Other.mkv
status:unrecoverable:d1:backup/bad.bin
not a tag: error:1:d1:x
EOF
PARSED="$(sre_parse_problem_tags "$LOG")"
eq "parse: unique problem rows" "5" "$(printf '%s\n' "$PARSED" | grep -c .)"
has "parse: checksum reason"    <(printf '%s' "$PARSED") $'d6\tmovies/My Film.mkv\tchecksum mismatch'
has "parse: missing reason"     <(printf '%s' "$PARSED") $'d1\tgone/file.txt\tmissing'
has "parse: recoverable status" <(printf '%s' "$PARSED") $'d6\tmovies/Other.mkv\trecoverable'
has "parse: unrecoverable"      <(printf '%s' "$PARSED") $'d1\tbackup/bad.bin\tunrecoverable'
has "parse: colon in path kept" <(printf '%s' "$PARSED") $'d1\tbackup/a:b.bin\tchecksum mismatch'
eq "parse: a non-tag line is ignored" "0" "$(printf '%s\n' "$PARSED" | grep -c 'not a tag' || true)"

# ---------------------------------------------------------------------------
# sre_log_summary / sre_log_error_count (block counts)
# ---------------------------------------------------------------------------
SLOG="$TMP/sync.log"
cat > "$SLOG" <<'EOF'
summary:added:10
summary:removed:2
summary:updated:3
summary:error_soft:1
summary:error_io:2
summary:error_data:0
EOF
eq "sre_log_error_count sums soft+io+data" "3" "$(sre_log_error_count "$SLOG")"
eq "sre_log_summary sync line" "10 added, 2 removed, 3 updated, 3 error(s)" "$(sre_log_summary "$SLOG" sync)"

# ---------------------------------------------------------------------------
# sre_latest_problem_log - picks the most recently STARTED detection run, not
# the first non-null state key, and reports its kind (tab separated).
# ---------------------------------------------------------------------------
cat > "$STATE_FILE" <<EOF
{"check_last_log":"$TMP/old-check.log","check_started":100,
 "scrub_last_log":"$TMP/new-scrub.log","scrub_started":200,
 "sync_last_log":"$TMP/newer-sync.log","sync_started":300}
EOF
eq "latest problem log = newest started (sync path)" "$TMP/newer-sync.log" "$(sre_latest_problem_log | cut -f2)"
eq "latest problem log = newest started (sync kind)" "sync" "$(sre_latest_problem_log | cut -f1)"
cat > "$STATE_FILE" <<EOF
{"check_last_log":"$TMP/old-check.log","check_started":100,
 "scrub_last_log":"$TMP/new-scrub.log","scrub_started":500}
EOF
eq "latest problem log = newest started (scrub kind)" "scrub" "$(sre_latest_problem_log | cut -f1)"
cat > "$STATE_FILE" <<EOF
{"check_last_log":"$TMP/old-check.log","scrub_last_log":"$TMP/new-scrub.log"}
EOF
eq "latest problem log falls back to key order (check kind)" "check" "$(sre_latest_problem_log | cut -f1)"
cat > "$STATE_FILE" <<'EOF'
{}
EOF
eq "latest problem log is empty when unconfigured" "" "$(sre_latest_problem_log)"

# ---------------------------------------------------------------------------
# sre_persist_log - bounded tail survives for the History tab.
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
BIG="$LOG_DIR/sync-1.log"
head -c 300000 /dev/zero | tr '\0' 'x' > "$BIG"
printf 'FINAL LINE\n' >> "$BIG"
sre_persist_log "$BIG"
PT="$PERSIST_LOG_DIR/sync-1.log.tail"
if [[ -f "$PT" ]]; then ok "persisted tail created"; else bad "persisted tail created"; fi
eq "sre_persist_log bounds the tail" "65536" "$(stat -c %s "$PT")"
if tail -c 20 "$PT" | grep -q 'FINAL LINE'; then ok "persisted tail keeps the end of the log"; else bad "persisted tail keeps the end of the log"; fi

# ---------------------------------------------------------------------------
# install_cron.sh: custom cron, invalid-cron warning file, manual mode.
# ---------------------------------------------------------------------------
export SRE_CRON_FILE="$TMP/cron.d"
printf 'SCHEDULE=custom\nCUSTOM_SYNC_CRON=15 2 * * 1,3,5\nCUSTOM_SCRUB_CRON=30 5 * * 0\n' > "$SET"
mkdir -p "$(dirname "$SRE_PLUGIN_HOME")"
out="$(bash "$SCRIPTS/install_cron.sh" 2>&1)"
has "cron: custom sync installed" "$SRE_CRON_FILE" '15 2 \* \* 1,3,5 bash .*sync\.sh'
has "cron: custom scrub installed" "$SRE_CRON_FILE" '30 5 \* \* 0 bash .*scrub\.sh'

printf 'SCHEDULE=custom\nCUSTOM_SYNC_CRON=bad cron here now ok\nCUSTOM_SCRUB_CRON=0 4 * * 0\n' > "$SET"
rm -f "$SRE_PLUGIN_HOME/cron-warning.txt"
out="$(bash "$SCRIPTS/install_cron.sh" 2>&1)"
if [[ -f "$SRE_PLUGIN_HOME/cron-warning.txt" ]]; then ok "cron: invalid custom writes warning file"; else bad "cron: invalid custom writes warning file"; fi
has "cron: invalid custom falls back to daily" "$SRE_CRON_FILE" '30 3 \* \* \* bash .*sync\.sh'

printf 'SCHEDULE=manual\n' > "$SET"
out="$(bash "$SCRIPTS/install_cron.sh" 2>&1)"
has "cron: manual keeps health check" "$SRE_CRON_FILE" 'alerts\.sh check'
if grep -q 'sync\.sh' "$SRE_CRON_FILE"; then bad "cron: manual removes sync"; else ok "cron: manual removes sync"; fi

# ---------------------------------------------------------------------------
# genconfig.sh - parity/content/data/exclude emission and raw-device rejection.
# ---------------------------------------------------------------------------
# genconfig validates mountpoints, so only exercise the pre-validation errors
# and the config text via a mounted-path shim is impractical here; instead test
# that missing parity/data fails cleanly.
printf 'PARITY_PATH=\nDATA_DISKS=\n' > "$SET"
if out="$(bash "$SCRIPTS/genconfig.sh" 2>&1)"; then
    bad "genconfig: aborts when unconfigured" "$out"
else
    ok "genconfig: aborts when unconfigured"
fi

# ---------------------------------------------------------------------------
# Version comparison helpers. Lexical compare is wrong (14.10 > 14.9), and a
# bare dotted version must not be stored as a JSON number (14.10 -> 14.1).
# ---------------------------------------------------------------------------
if sre_version_ge 14.10 14.9; then ok "sre_version_ge: 14.10 >= 14.9"; else bad "sre_version_ge: 14.10 >= 14.9"; fi
if sre_version_ge 14.9 14.10; then bad "sre_version_ge: 14.9 < 14.10"; else ok "sre_version_ge: 14.9 < 14.10"; fi
if sre_version_ge 14.10 14.10; then ok "sre_version_ge: equal versions"; else bad "sre_version_ge: equal versions"; fi
if sre_version_ge 14.10.1 14.10; then ok "sre_version_ge: patch > minor"; else bad "sre_version_ge: patch > minor"; fi
if sre_version_ge v14.10 v14.9; then ok "sre_version_ge: tolerates a leading v"; else bad "sre_version_ge: tolerates a leading v"; fi
eq "sre_snapraid_ver_num 14.9"  "1409" "$(sre_snapraid_ver_num 14.9)"
eq "sre_snapraid_ver_num 14.10" "1410" "$(sre_snapraid_ver_num 14.10)"
eq "sre_snapraid_ver_num v14.10" "1410" "$(sre_snapraid_ver_num v14.10)"

# ---------------------------------------------------------------------------
# alerts.sh check #4 "scrub overdue" keys off the last COMPLETED scrub, not
# snapraid's scrub_oldest_days. That value is the age of the single oldest
# block, which for a percentage-based scrub (-p 12 -o 10) is a normal tail and
# fired a false alert on a healthy, recently-scrubbed array.
# ---------------------------------------------------------------------------
export NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/fake-notify" <<'EOF'
#!/bin/bash
echo "$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/fake-notify"

ASET="$TMP/alerts-settings.ini"
cat > "$ASET" <<'EOF'
ALERT_SYNC_OK=0
ALERT_SYNC_ERROR=0
ALERT_SYNC_CONFIRM=0
ALERT_SCRUB_OK=0
ALERT_SCRUB_ISSUES=0
ALERT_RECOVER_OK=0
ALERT_RECOVER_ERROR=0
ALERT_CANCELLED=0
ALERT_PARITY_STALE=0
ALERT_DISK_OFFLINE=0
ALERT_PARITY_SPACE=0
ALERT_SCRUB_OVERDUE=1
ALERT_CONTENT_STALE=0
ALERT_PARITY_MISSING=0
ALERT_UNRECOVERED=0
ALERT_SCRUB_OVERDUE_DAYS=30
DATA_DISKS=
PARITY_PATH=
PARITY2_PATH=
CONTENT_DISKS=
EOF

export SRE_SETTINGS_FILE="$ASET"
export SRE_STATE_FILE="$TMP/alerts-state.json"
export SRE_NOTIFY_BIN="$TMP/fake-notify"

run_alerts() { rm -f "$NOTIFY_LOG"; bash "$SCRIPTS/alerts.sh" check >/dev/null 2>&1; }
NOW=$(date +%s)

printf '{"scrub_finished":%s}\n' "$NOW" > "$SRE_STATE_FILE"
run_alerts
if [[ ! -s "$NOTIFY_LOG" ]]; then ok "alerts: recently scrubbed array does not warn"; else bad "alerts: recently scrubbed array does not warn" "$(cat "$NOTIFY_LOG")"; fi

printf '{"scrub_finished":%s,"snapraid_scrub_oldest_days":32}\n' "$NOW" > "$SRE_STATE_FILE"
run_alerts
if [[ ! -s "$NOTIFY_LOG" ]]; then ok "alerts: old oldest-block with a recent scrub does not warn"; else bad "alerts: old oldest-block with a recent scrub does not warn" "$(cat "$NOTIFY_LOG")"; fi

printf '{"scrub_finished":%s}\n' "$((NOW - 40*86400))" > "$SRE_STATE_FILE"
run_alerts
if grep -q "Scrub overdue" "$NOTIFY_LOG"; then ok "alerts: genuinely stale scrub warns"; else bad "alerts: genuinely stale scrub warns"; fi

printf '{}\n' > "$SRE_STATE_FILE"
run_alerts
if [[ ! -s "$NOTIFY_LOG" ]]; then ok "alerts: never-scrubbed array does not warn yet"; else bad "alerts: never-scrubbed array does not warn yet" "$(cat "$NOTIFY_LOG")"; fi

unset SRE_NOTIFY_BIN

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
