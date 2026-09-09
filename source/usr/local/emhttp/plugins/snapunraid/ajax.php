<?php
/*
 * SnapUnraid - AJAX endpoint.
 *
 * Unraid's nginx returns 405 Not Allowed for POST requests to .page files, so
 * the AJAX handler MUST live in its own .php endpoint that nginx will route.
 * The front-end posts to /plugins/snapunraid/ajax.php and this file returns
 * only clean JSON (no page header/metadata text ever prepended).
 */
$plugin      = "snapunraid";
$scriptDir   = "/usr/local/emhttp/plugins/{$plugin}/scripts";
$settingsIni = "/boot/config/plugins/{$plugin}/settings.ini";

header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !isset($_POST['sre_action'])) {
    echo json_encode(['ok' => false, 'error' => 'bad request']);
    exit;
}

$action = $_POST['sre_action'];

// Cancel a running sync/scrub. The wrapper scripts are started with `setsid`,
// so the PID they record in state.json is also their process-group id; a
// `kill -TERM -- -PID` signals the whole group (wrapper + snapraid). We only
// kill if the PID is still alive AND its command line is one of ours, so a
// stale/recycled PID can never take down an unrelated process.
function sre_cancel_operation($pidKey) {
    $stateRaw = @file_get_contents('/var/local/snapunraid/state.json');
    $stateArr = json_decode($stateRaw, true) ?: [];
    $pid = intval($stateArr[$pidKey] ?? 0);
    if ($pid <= 0) {
        return ['ok' => false, 'error' => 'no running operation'];
    }
    $cmdline = @file_get_contents("/proc/{$pid}/cmdline");
    if ($cmdline === false || (strpos($cmdline, 'snapunraid') === false && strpos($cmdline, 'snapraid') === false)) {
        return ['ok' => false, 'error' => 'process not found or not ours'];
    }
    shell_exec("kill -TERM -- -{$pid} 2>/dev/null");
    return ['ok' => true];
}

// Merge key=value pairs into settings.ini, preserving any keys not being
// updated (e.g. the alert toggles when the Setup form is saved, and vice
// versa). Reads the existing file, applies the updates, writes it back.
function sre_ini_merge($updates) {
    global $settingsIni;
    $existing = [];
    if (file_exists($settingsIni)) {
        foreach (file($settingsIni) as $line) {
            $line = rtrim($line);
            if ($line === '' || strpos($line, '=') === false) continue;
            list($k, $v) = explode('=', $line, 2);
            $existing[$k] = $v;
        }
    }
    foreach ($updates as $k => $v) { $existing[$k] = $v; }
    $out = '';
    foreach ($existing as $k => $v) { $out .= "{$k}={$v}\n"; }
    @mkdir(dirname($settingsIni), 0755, true);
    file_put_contents($settingsIni, $out);
}

switch ($action) {
    // All scripts are invoked through `bash` explicitly because the Unraid
    // plugin inliner writes files but does not reliably preserve the
    // executable bit -- routing through bash avoids depending on +x.
    case 'get_disks':
        echo shell_exec("bash {$scriptDir}/status.sh disks");
        break;

    case 'get_state':
        echo shell_exec("bash {$scriptDir}/status.sh state");
        break;

    case 'get_status':
        // Cached snapraid status summary (files/size/parity age). Kicks off a
        // background refresh when the cache is stale; never blocks.
        echo shell_exec("bash {$scriptDir}/status.sh status");
        break;

    case 'install_snapraid':
        $force = ($_POST['force'] ?? '') === '1' ? '--force-redownload' : '';
        // background so the first-time download doesn't block the UI; poll get_install_state
        shell_exec("nohup bash {$scriptDir}/install_snapraid.sh {$force} > /dev/null 2>&1 &");
        echo json_encode(['ok' => true, 'started' => true]);
        break;

    case 'get_install_state':
        echo shell_exec("bash {$scriptDir}/status.sh state");
        break;

    case 'save_setup':
        // Refuse to save if snapraid itself isn't installed yet - saving
        // would generate a config for a binary that doesn't exist.
        $stateRaw = shell_exec("bash {$scriptDir}/status.sh state");
        $stateArr = json_decode($stateRaw, true) ?: [];
        if (empty($stateArr['snapraid_installed'])) {
            echo json_encode(['ok' => false, 'error' => 'SnapRAID is not installed yet. Click "Install SnapRAID" above first.']);
            break;
        }

        $parity   = escapeshellarg($_POST['parity_path'] ?? '');
        $dataArr  = json_decode($_POST['data_disks'] ?? '[]', true) ?: [];
        $contentArr = json_decode($_POST['content_disks'] ?? '[]', true) ?: [];
        $excludes = $_POST['excludes'] ?? '';
        $schedule = $_POST['schedule'] ?? 'daily';
        $threshold = intval($_POST['delete_threshold'] ?? 50);

        sre_ini_merge([
            'PARITY_PATH' => trim($_POST['parity_path'] ?? ''),
            'PARITY2_PATH' => trim($_POST['parity2_path'] ?? ''),
            'DATA_DISKS' => implode(',', $dataArr),
            'CONTENT_DISKS' => implode(',', $contentArr),
            'EXCLUDES' => trim($excludes),
            'SCHEDULE' => trim($schedule),
            'CUSTOM_SYNC_CRON' => trim($_POST['custom_sync_cron'] ?? ''),
            'CUSTOM_SCRUB_CRON' => trim($_POST['custom_scrub_cron'] ?? ''),
            'DELETE_THRESHOLD_COUNT' => $threshold,
        ]);

        // regenerate snapraid.conf and (re)install the cron schedule
        $genOut = shell_exec("bash {$scriptDir}/genconfig.sh 2>&1");
        $cronOut = shell_exec("bash {$scriptDir}/install_cron.sh 2>&1");

        echo json_encode(['ok' => true, 'genconfig' => trim($genOut), 'cron' => trim($cronOut)]);
        break;

    case 'import_config':
        // Import an existing snapraid.conf into the plugin (parity/data/
        // content/exclude -> settings.ini, then regenerate). Path is
        // shell-escaped; the script also auto-detects common locations.
        $path = $_POST['path'] ?? '';
        echo shell_exec("bash {$scriptDir}/import_config.sh " . escapeshellarg($path));
        break;

    case 'save_alerts':
        // Alert toggles + thresholds from the Alerts tab. Merged into
        // settings.ini so the Setup keys are preserved.
        $toggles = [
            'ALERT_SYNC_OK' => '0', 'ALERT_SYNC_ERROR' => '1', 'ALERT_SYNC_CONFIRM' => '1',
            'ALERT_SCRUB_OK' => '0', 'ALERT_SCRUB_ISSUES' => '1',
            'ALERT_RECOVER_OK' => '0', 'ALERT_RECOVER_ERROR' => '1', 'ALERT_CANCELLED' => '0',
            'ALERT_PARITY_STALE' => '1', 'ALERT_DISK_OFFLINE' => '1',
            'ALERT_PARITY_SPACE' => '1', 'ALERT_SCRUB_OVERDUE' => '1',
            'ALERT_CONTENT_STALE' => '1', 'ALERT_PARITY_MISSING' => '1', 'ALERT_UNRECOVERED' => '1',
        ];
        $nums = [
            'ALERT_PARITY_STALE_DAYS' => 30, 'ALERT_PARITY_SPACE_PCT' => 10, 'ALERT_SCRUB_OVERDUE_DAYS' => 30,
        ];
        $updates = [];
        foreach ($toggles as $k => $def) {
            $updates[$k] = ($_POST[$k] ?? '') === '1' ? '1' : '0';
        }
        foreach ($nums as $k => $def) {
            $v = intval($_POST[$k] ?? $def);
            $updates[$k] = max(1, min(365, $v));
        }
        sre_ini_merge($updates);
        echo json_encode(['ok' => true]);
        break;

    case 'test_notify':
        // Fire a test notification through the same pipeline the alerts use,
        // so the user can confirm Unraid delivery (email/agent/bell) works.
        echo shell_exec("bash {$scriptDir}/notify.sh test 2>&1");
        break;

    case 'run_sync':
        $force = ($_POST['force'] ?? '') === '1' ? '--force' : '';
        // run in background so the UI doesn't block; poll get_state for progress.
        // setsid gives the wrapper its own process group so the webGUI can
        // cancel it later by signalling the whole group.
        shell_exec("setsid bash {$scriptDir}/sync.sh {$force} > /dev/null 2>&1 &");
        echo json_encode(['ok' => true, 'started' => true]);
        break;

    case 'run_scrub':
        shell_exec("setsid bash {$scriptDir}/scrub.sh > /dev/null 2>&1 &");
        echo json_encode(['ok' => true, 'started' => true]);
        break;

    case 'cancel_sync':
        echo json_encode(sre_cancel_operation('sync_pid'));
        break;

    case 'cancel_scrub':
        echo json_encode(sre_cancel_operation('scrub_pid'));
        break;

    case 'cancel_check':
        echo json_encode(sre_cancel_operation('check_pid'));
        break;

    case 'cancel_pending':
        // A sync paused at the confirmation screen has no running process to
        // signal - sync.sh already exited. Mark it cancelled and drop the
        // pending counts so the confirmation doesn't reappear on refresh.
        $stateFile = '/var/local/snapunraid/state.json';
        $stateArr = json_decode(@file_get_contents($stateFile), true) ?: [];
        if (($stateArr['sync_status'] ?? '') !== 'needs_confirmation') {
            echo json_encode(['ok' => false, 'error' => 'no pending sync to cancel']);
            break;
        }
        $stateArr['sync_status'] = 'cancelled';
        unset($stateArr['sync_pending_added'], $stateArr['sync_pending_removed'],
              $stateArr['sync_pending_updated'], $stateArr['sync_pending_log']);
        $tmp = $stateFile . '.tmp';
        if (file_put_contents($tmp, json_encode($stateArr) . "\n") === false || !rename($tmp, $stateFile)) {
            echo json_encode(['ok' => false, 'error' => 'could not update state']);
            break;
        }
        echo json_encode(['ok' => true]);
        break;

    case 'get_problems':
        echo shell_exec("bash {$scriptDir}/recover.sh list");
        break;

    case 'get_history':
        echo shell_exec("bash {$scriptDir}/status.sh history");
        break;

    case 'backup_config':
        echo shell_exec("bash {$scriptDir}/backup.sh backup");
        break;

    case 'list_backups':
        echo shell_exec("bash {$scriptDir}/backup.sh list");
        break;

    case 'restore_config':
        $name = escapeshellarg($_POST['name'] ?? '');
        echo shell_exec("bash {$scriptDir}/backup.sh restore {$name}");
        break;

    case 'delete_backup':
        $name = escapeshellarg($_POST['name'] ?? '');
        echo shell_exec("bash {$scriptDir}/backup.sh delete {$name}");
        break;

    case 'run_check':
        // Full array check (errors only), in the background so the UI doesn't
        // block; poll get_check_state for progress and results.
        shell_exec("setsid bash {$scriptDir}/recover.sh check > /dev/null 2>&1 &");
        echo json_encode(['ok' => true, 'started' => true]);
        break;

    case 'get_check_state':
        $stateRaw = shell_exec("bash {$scriptDir}/status.sh state");
        $stateArr = json_decode($stateRaw, true) ?: [];
        $problems = $stateArr['check_problems'] ?? '[]';
        if (is_string($problems)) { $problems = json_decode($problems, true) ?: []; }
        echo json_encode([
            'status'   => $stateArr['check_status'] ?? '',
            'progress' => $stateArr['check_progress'] ?? '',
            'problems' => $problems,
        ]);
        break;

    case 'fix_disk':
        $disk = escapeshellarg($_POST['disk'] ?? '');
        echo shell_exec("bash {$scriptDir}/recover.sh fix {$disk}");
        break;

    case 'fix_file':
        $path = escapeshellarg($_POST['path'] ?? '');
        echo shell_exec("bash {$scriptDir}/recover.sh fix-file {$path}");
        break;

    case 'fix_all':
        echo shell_exec("bash {$scriptDir}/recover.sh fix-all");
        break;

    case 'get_pending_changes':
        // A sync paused at the confirmation screen keeps its diff in the
        // pending log. Read it from state and surface the exact files that
        // would be added/removed so the user can review before confirming.
        $stateRaw = @file_get_contents('/var/local/snapunraid/state.json');
        $stateArr = json_decode($stateRaw, true) ?: [];
        $log = $stateArr['sync_pending_log'] ?? '';
        if (!preg_match('#^/var/local/snapunraid/logs/[A-Za-z0-9._-]+\.log$#', $log) || !file_exists($log)) {
            echo json_encode(['ok' => false, 'error' => 'no pending sync changes available']);
            break;
        }
        $removed = [];
        $added = [];
        foreach (file($log) as $line) {
            $line = trim($line);
            // snapraid diff prefixes each changed path with "add "/"remove "
            // and backslash-escapes spaces/parens/quotes - unescape them.
            if (preg_match('/^remove (.*)$/', $line, $m)) {
                $removed[] = preg_replace('/\\\\(.)/', '$1', $m[1]);
            } elseif (preg_match('/^add (.*)$/', $line, $m)) {
                $added[] = preg_replace('/\\\\(.)/', '$1', $m[1]);
            }
        }
        echo json_encode(['ok' => true, 'removed' => $removed, 'added' => $added]);
        break;

    case 'get_log':
        $path = $_POST['path'] ?? '';
        // only allow reading logs from our own log directory
        if (preg_match('#^/var/local/snapunraid/logs/[A-Za-z0-9._-]+\.log$#', $path) && file_exists($path)) {
            // Return only the tail of the log. Sync logs can be tens of MB of
            // progress lines; the History tab only needs the end (summary,
            // errors, final status). The full log stays on disk for debugging.
            $maxBytes = 200 * 1024;
            $size = filesize($path);
            $offset = max(0, $size - $maxBytes);
            $content = file_get_contents($path, false, null, $offset);
            echo json_encode([
                'ok' => true,
                'content' => $content,
                'truncated' => $size > $maxBytes,
                'total_bytes' => $size,
            ]);
        } else {
            echo json_encode(['ok' => false, 'error' => 'invalid log path']);
        }
        break;

    default:
        echo json_encode(['ok' => false, 'error' => 'unknown action']);
}
exit;
