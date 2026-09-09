(function () {
    'use strict';

    function post(action, extra) {
        // Unraid's webGUI rejects POSTs to plugin endpoints without a valid
        // csrf_token (missing csrf_token error). Inject it on every request.
        const params = new URLSearchParams(Object.assign({ sre_action: action, csrf_token: SRE_CSRF || '' }, extra || {}));
        return fetch(SRE_AJAX, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: params
        }).then(r => r.json());
    }

    function humanBytes(n) {
        if (!n) return '0 B';
        const u = ['B', 'KB', 'MB', 'GB', 'TB'];
        let i = 0;
        while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
        return n.toFixed(1) + ' ' + u[i];
    }

    function timeAgo(unixSeconds) {
        if (!unixSeconds) return 'never';
        const diff = Math.floor(Date.now() / 1000) - unixSeconds;
        if (diff < 60) return 'just now';
        if (diff < 3600) return Math.floor(diff / 60) + ' min ago';
        if (diff < 86400) return Math.floor(diff / 3600) + ' hr ago';
        return Math.floor(diff / 86400) + ' day(s) ago';
    }

    // -------------------------------------------------------------------
    // Tabs
    // -------------------------------------------------------------------
    document.querySelectorAll('.sre-tab-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.sre-tab-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            document.querySelectorAll('.sre-tab-panel').forEach(p => p.style.display = 'none');
            document.getElementById('tab-' + btn.dataset.tab).style.display = 'block';
            if (btn.dataset.tab === 'setup') loadSetup();
            if (btn.dataset.tab === 'backup') loadBackup();
            if (btn.dataset.tab === 'recover') loadRecover();
            if (btn.dataset.tab === 'history') loadHistory();
            if (btn.dataset.tab === 'alerts') loadAlerts();
        });
    });

    // -------------------------------------------------------------------
    // Dashboard
    // -------------------------------------------------------------------
    function refreshDashboard() {
        post('get_state').then(state => {
            const light = document.getElementById('sre-status-light');
            const headline = document.getElementById('sre-status-headline');
            const sub = document.getElementById('sre-status-sub');
            if (!light) return; // not configured yet, dashboard shows setup banner instead

            let cls = 'ok', text = 'Protected';
            if (state.sync_status === 'error' || state.scrub_status === 'issues_found') {
                cls = 'error'; text = 'Attention needed';
            } else if (state.sync_status === 'needs_confirmation' || state.sync_status === 'running' || state.scrub_status === 'running') {
                cls = 'warn'; text = 'In progress / needs review';
            } else if (state.sync_status === 'cancelled' || state.scrub_status === 'cancelled') {
                cls = 'warn'; text = 'Cancelled';
            }
            light.className = 'sre-status-light ' + cls;
            headline.textContent = text;
            sub.textContent = 'Last sync: ' + timeAgo(state.sync_finished) + '  |  Last scrub: ' + timeAgo(state.scrub_finished);

            // Array status summary (cached snapraid status, refreshed in the
            // background by get_status every few minutes).
            const arrayStatusEl = document.getElementById('sre-array-status');
            if (arrayStatusEl) {
                const fc = state.snapraid_file_count;
                if (fc !== undefined && fc > 0) {
                    const parts = [
                        `${fc.toLocaleString()} files`,
                        'Data: ' + humanBytes(state.snapraid_file_size),
                        `Array: ${state.snapraid_use_percent || 0}% used`
                    ];
                    const pa = state.snapraid_parity_age_days;
                    if (pa !== undefined && pa !== '') parts.push(`Parity: ${pa} day(s) old`);
                    const pa2 = state.snapraid_parity2_age_days;
                    if (pa2 !== undefined && pa2 !== '') parts.push(`Parity-2: ${pa2} day(s) old`);
                    arrayStatusEl.textContent = parts.join('  |  ');
                } else if (fc === 0) {
                    arrayStatusEl.textContent = 'Array is empty - run your first sync to start protecting data.';
                } else {
                    arrayStatusEl.textContent = 'Loading array status...';
                }
            }

            // Warn when parity is stale (older than a week).
            const staleWarn = document.getElementById('sre-parity-stale-warning');
            if (staleWarn) {
                const pa = state.snapraid_parity_age_days;
                if (pa !== undefined && pa !== '' && pa > 7) {
                    staleWarn.style.display = 'block';
                    staleWarn.textContent = `Parity is ${pa} days old. Run a sync to keep your data protected.`;
                } else {
                    staleWarn.style.display = 'none';
                }
            }

            document.getElementById('sre-sync-detail').textContent =
                state.sync_status === 'running' ? ('Sync in progress...' + (state.sync_progress ? ` ${state.sync_progress}%` : '') + (state.sync_eta ? ` (ETA ${state.sync_eta})` : '')) :
                (state.sync_status === 'cancelled' ? 'Sync cancelled' :
                (state.sync_last_added !== undefined
                    ? `${state.sync_last_added || 0} added, ${state.sync_last_removed || 0} removed, ${state.sync_last_updated || 0} updated`
                    : 'No sync run yet'));

            document.getElementById('sre-scrub-detail').textContent =
                state.scrub_status === 'running' ? ('Scrub in progress...' + (state.scrub_progress ? ` ${state.scrub_progress}%` : '') + (state.scrub_eta ? ` (ETA ${state.scrub_eta})` : '')) :
                (state.scrub_status === 'cancelled' ? 'Scrub cancelled' :
                (state.scrub_last_bad_files !== undefined
                    ? (state.scrub_last_bad_files > 0 ? `${state.scrub_last_bad_files} file(s) flagged` : 'No corruption found')
                    : 'No scrub run yet'));

            // Show the Cancel button only while the matching operation is running.
            const syncStopBtn = document.getElementById('sre-btn-sync-stop');
            if (syncStopBtn) syncStopBtn.style.display = state.sync_status === 'running' ? 'inline-block' : 'none';
            const scrubStopBtn = document.getElementById('sre-btn-scrub-stop');
            if (scrubStopBtn) scrubStopBtn.style.display = state.scrub_status === 'running' ? 'inline-block' : 'none';

            const confirmBox = document.getElementById('sre-sync-confirm');
            const changesBtn = document.getElementById('sre-btn-sync-show-changes');
            if (state.sync_status === 'needs_confirmation') {
                confirmBox.style.display = 'block';
                confirmBox.querySelector('p').textContent =
                    `This sync would add ${state.sync_pending_added || 0}, remove ${state.sync_pending_removed || 0} and update ${state.sync_pending_updated || 0} files - that is above your safety threshold. Review the changes before continuing, and make sure no disk dropped offline.`;
                if (changesBtn) {
                    changesBtn.style.display = '';
                    changesBtn.textContent = `Show files to be removed (${state.sync_pending_removed || 0})`;
                }
            } else {
                confirmBox.style.display = 'none';
                if (changesBtn) { changesBtn.style.display = 'none'; changesBtn.textContent = 'Show files to be removed'; }
            }

            const logList = document.getElementById('sre-log-list');
            if (logList) {
                const entries = [];
                if (state.sync_finished) entries.push({ t: state.sync_finished, label: 'Sync', ok: state.sync_status === 'ok' });
                if (state.scrub_finished) entries.push({ t: state.scrub_finished, label: 'Scrub', ok: state.scrub_status === 'ok' });
                entries.sort((a, b) => b.t - a.t);
                logList.innerHTML = entries.length ? entries.map(e =>
                    `<div class="sre-log-entry"><span>${e.label} - ${e.ok ? 'OK' : 'see status above'}</span><span class="sre-log-time">${timeAgo(e.t)}</span></div>`
                ).join('') : 'No activity yet.';
            }
        });
    }

    const syncBtn = document.getElementById('sre-btn-sync');
    if (syncBtn) syncBtn.addEventListener('click', () => {
        post('run_sync', {}).then(() => setTimeout(refreshDashboard, 1500));
    });
    const syncForceBtn = document.getElementById('sre-btn-sync-force');
    if (syncForceBtn) syncForceBtn.addEventListener('click', () => {
        post('run_sync', { force: '1' }).then(() => setTimeout(refreshDashboard, 1500));
    });
    // Cancel a sync that's PAUSED at the confirmation screen. There's no
    // process running to kill (sync.sh already exited) - mark it cancelled in
    // state so the confirmation doesn't reappear on refresh.
    const syncCancelBtn = document.getElementById('sre-btn-sync-cancel');
    if (syncCancelBtn) syncCancelBtn.addEventListener('click', () => {
        syncCancelBtn.textContent = 'Cancelling...';
        post('cancel_pending').then(() => refreshDashboard()).catch(() => {
            syncCancelBtn.textContent = 'Cancel';
        });
    });
    // Review the exact files a paused sync would add/remove before confirming.
    // Opens in a modal (same look as the run-log viewer) so the confirmation
    // box stays compact; Close and click-outside dismiss it.
    const showChangesBtn = document.getElementById('sre-btn-sync-show-changes');
    if (showChangesBtn) showChangesBtn.addEventListener('click', () => {
        const originalLabel = showChangesBtn.textContent;
        showChangesBtn.textContent = 'Loading...';
        post('get_pending_changes').then(res => {
            showChangesBtn.textContent = originalLabel;
            if (!res.ok) { alert(res.error || 'Could not load changes.'); return; }
            const rem = res.removed || [];
            const add = res.added || [];
            const html = [];
            if (rem.length) {
                html.push('<div class="sre-chg-head">Files that would be REMOVED (' + rem.length + '):</div>');
                rem.forEach(p => html.push('<div class="sre-chg-removed">' + esc(p) + '</div>'));
            }
            if (add.length) {
                html.push('<div class="sre-chg-head">Files that would be ADDED (' + add.length + '):</div>');
                add.forEach(p => html.push('<div class="sre-chg-added">' + esc(p) + '</div>'));
            }
            const modal = document.createElement('div');
            modal.className = 'sre-log-modal';
            modal.innerHTML = '<div class="sre-log-modal-box sre-changes-modal">' +
                '<h3>Changes this sync would make</h3>' +
                '<div class="sre-changes-scroll">' +
                (html.join('') || '<span style="opacity:.7">No changes detected.</span>') +
                '</div>' +
                '<button class="sre-btn" data-close>Close</button></div>';
            document.body.appendChild(modal);
            modal.addEventListener('click', ev => { if (ev.target.hasAttribute('data-close') || ev.target === modal) modal.remove(); });
        }).catch(() => { showChangesBtn.textContent = originalLabel; });
    });
    const scrubBtn = document.getElementById('sre-btn-scrub');
    if (scrubBtn) scrubBtn.addEventListener('click', () => {
        post('run_scrub', {}).then(() => setTimeout(refreshDashboard, 1500));
    });
    const syncStopBtn = document.getElementById('sre-btn-sync-stop');
    if (syncStopBtn) syncStopBtn.addEventListener('click', () => {
        post('cancel_sync', {}).then(() => setTimeout(refreshDashboard, 1500));
    });
    const scrubStopBtn = document.getElementById('sre-btn-scrub-stop');
    if (scrubStopBtn) scrubStopBtn.addEventListener('click', () => {
        post('cancel_scrub', {}).then(() => setTimeout(refreshDashboard, 1500));
    });

    // Kick the cached snapraid status summary. get_status returns the current
    // cache immediately and starts a background refresh when it's stale, so
    // this never blocks the Dashboard. The values land in state.json and are
    // picked up by the next refreshDashboard() poll.
    function refreshArrayStatus() {
        post('get_status', {});
    }

    if (document.getElementById('sre-status-light')) {
        refreshDashboard();
        setInterval(refreshDashboard, 8000);
        refreshArrayStatus();
        setInterval(refreshArrayStatus, 300000); // refresh cached status every 5 min
    }

    // -------------------------------------------------------------------
    // -------------------------------------------------------------------
    // History
    // -------------------------------------------------------------------
    function loadHistory() {
        const list = document.getElementById('sre-history-list');
        if (!list) return;
        list.textContent = 'Loading...';
        post('get_history').then(rows => {
            if (!Array.isArray(rows) || rows.length === 0) {
                list.innerHTML = '<span style="opacity:.6">No runs yet. A Sync or Scrub will appear here when completed.</span>';
                return;
            }
            const statusText = { ok: 'OK', error: 'Error', paused: 'Paused', issues: 'Issues found', cancelled: 'Cancelled' };
            const esc = s => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
            list.innerHTML = '<table class="sre-history-table"><thead><tr><th>Type</th><th>Result</th><th>Details</th><th>When</th></tr></thead><tbody>' +
                rows.map(r => {
                    const dt = new Date(r.ts * 1000);
                    let detail = r.message || r.status || 'failed';
                    if (r.status === 'ok' || r.status === 'paused') {
                        if (r.type === 'scrub') {
                            detail = (r.bad_files ? r.bad_files + ' problem(s)' : 'no problems');
                        } else {
                            detail = [r.added ? r.added + ' added' : '', r.removed ? r.removed + ' removed' : '', r.updated ? r.updated + ' updated' : ''].filter(Boolean).join(', ') || 'no changes';
                        }
                    }
                    const cls = (r.status === 'error' || r.status === 'issues') ? 'sre-hist-bad' : (r.status === 'paused' || r.status === 'cancelled') ? 'sre-hist-warn' : 'sre-hist-ok';
                    const type = r.type === 'scrub' ? 'Scrub' : 'Sync';
                    const logAttr = r.log ? ' data-log="' + esc(r.log) + '"' : '';
                    return '<tr class="sre-hist-row ' + cls + '"' + logAttr + '><td>' + type + '</td><td>' + (statusText[r.status] || r.status) + '</td><td>' + esc(detail) + '</td><td>' + dt.toLocaleString() + '</td></tr>';
                }).join('') + '</tbody></table>';

            Array.from(list.querySelectorAll('.sre-hist-row')).forEach(row => {
                row.addEventListener('click', () => {
                    const logPath = row.getAttribute('data-log');
                    if (!logPath) return;
                    post('get_log', { path: logPath }).then(res => {
                        if (!res.ok) {
                            const modal = document.createElement('div');
                            modal.className = 'sre-log-modal';
                            modal.innerHTML = '<div class="sre-log-modal-box"><h3>Run log</h3><p style="opacity:.8">This run\'s log is no longer available. Logs are stored in memory and cleared when the server reboots.</p><button class="sre-btn" data-close>Close</button></div>';
                            document.body.appendChild(modal);
                            modal.addEventListener('click', ev => { if (ev.target.hasAttribute('data-close') || ev.target === modal) modal.remove(); });
                            return;
                        }
                        const content = res.content || '(no log content)';
                        const note = res.truncated
                            ? '<div class="sre-log-note">Showing the last 200 KB of the log (full log is ' + humanBytes(res.total_bytes || 0) + ', kept on disk).</div>'
                            : '';
                        const modal = document.createElement('div');
                        modal.className = 'sre-log-modal';
                        modal.innerHTML = '<div class="sre-log-modal-box"><h3>Run log</h3>' + note + '<pre>' + esc(content) + '</pre><button class="sre-btn" data-close>Close</button></div>';
                        document.body.appendChild(modal);
                        modal.addEventListener('click', ev => { if (ev.target.hasAttribute('data-close') || ev.target === modal) modal.remove(); });
                    });
                });
            });
        });
    }
    // First-run auto-install: kick off the SnapRAID install check as soon
    // as the plugin page loads at all, regardless of which tab is active,
    // so it's likely already done/in-progress by the time the user opens
    // the Setup tab.
    // -------------------------------------------------------------------
    post('get_install_state').then(state => {
        if (!state.snapraid_installed && !state.install_snapraid_status) {
            post('install_snapraid', {});
        }
    });

    // -------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------
    let setupLoaded = false;
    let installPollTimer = null;

    function refreshInstallState() {
        return post('get_install_state').then(state => {
            const detail = document.getElementById('sre-install-detail');
            const installBtn = document.getElementById('sre-btn-install-snapraid');
            const setupBody = document.getElementById('sre-setup-body');

            if (state.snapraid_installed) {
                detail.textContent = 'Installed: ' + (state.snapraid_version || 'snapraid');
                installBtn.style.display = 'none';
                setupBody.style.display = 'block';
                if (installPollTimer) { clearInterval(installPollTimer); installPollTimer = null; }
            } else if (state.install_snapraid_status === 'running') {
                detail.textContent = state.install_snapraid_message || 'Installing...';
                installBtn.style.display = 'none';
                setupBody.style.display = 'none';
            } else if (state.install_snapraid_status === 'error') {
                detail.textContent = 'Install failed: ' + (state.install_snapraid_message || 'unknown error');
                installBtn.textContent = 'Retry Install';
                installBtn.style.display = 'inline-block';
                setupBody.style.display = 'none';
                if (installPollTimer) { clearInterval(installPollTimer); installPollTimer = null; }
            } else {
                detail.textContent = 'SnapRAID is not installed yet.';
                installBtn.textContent = 'Install SnapRAID';
                installBtn.style.display = 'inline-block';
                setupBody.style.display = 'none';
            }
            return state;
        });
    }

    const installBtn = document.getElementById('sre-btn-install-snapraid');
    if (installBtn) installBtn.addEventListener('click', () => {
        document.getElementById('sre-install-detail').textContent = 'Starting install...';
        installBtn.style.display = 'none';
        post('install_snapraid', {}).then(() => {
            if (installPollTimer) clearInterval(installPollTimer);
            installPollTimer = setInterval(refreshInstallState, 3000);
        });
    });

    function loadSetup() {
        // Always refresh install state on tab open (cheap, and catches manual fixes)
        refreshInstallState().then(state => {
            // Auto-trigger install on first visit if nothing has been attempted yet
            if (!state.snapraid_installed && !state.install_snapraid_status && !setupLoaded) {
                post('install_snapraid', {}).then(() => {
                    if (installPollTimer) clearInterval(installPollTimer);
                    installPollTimer = setInterval(refreshInstallState, 3000);
                });
            }
        });

        if (setupLoaded) return;
        setupLoaded = true;
        post('get_disks').then(disks => {
            const paritySel = document.getElementById('sre-parity-select');
            const parity2Sel = document.getElementById('sre-parity2-select');
            const checklist = document.getElementById('sre-disk-checklist');
            const dataLabels = {};   // rel -> checklist <label>, for parity-availability syncing
            paritySel.innerHTML = '<option value="">-- choose a disk --</option>';
            if (parity2Sel) parity2Sel.innerHTML = '<option value="">None (single parity)</option>';
            checklist.innerHTML = '';

            disks.forEach(d => {
                // Raw (unformatted) devices can't be used as parity - SnapRAID
                // needs a file on a mounted filesystem. Show them disabled so
                // the user understands why their disk isn't selectable.
                if (d.type === 'raw') {
                    const opt = document.createElement('option');
                    opt.value = d.rel;
                    opt.disabled = true;
                    opt.textContent = `${d.name} (raw) - ${humanBytes(d.size_bytes)} — not supported, format as a pool first`;
                    paritySel.appendChild(opt);
                    if (parity2Sel) parity2Sel.appendChild(opt.cloneNode(true));
                    return;
                }

                // Select values are the path relative to /mnt (d.rel), e.g.
                // "disk1" or "disks/snapunraid" - that's what settings.ini
                // stores and what genconfig.sh re-expands as /mnt/<rel>.
                const opt = document.createElement('option');
                opt.value = d.rel;
                opt.textContent = `${d.name} (${d.type}) - ${humanBytes(d.size_bytes)}`;
                if (d.rel === SRE_PRESELECTED_PARITY) opt.selected = true;
                paritySel.appendChild(opt);

                if (parity2Sel) {
                    const opt2 = document.createElement('option');
                    opt2.value = d.rel;
                    opt2.textContent = `${d.name} (${d.type}) - ${humanBytes(d.size_bytes)}`;
                    if (d.rel === SRE_PRESELECTED_PARITY2) opt2.selected = true;
                    parity2Sel.appendChild(opt2);
                }

                // Data-disk checklist: only mounted disks can hold data.
                const label = document.createElement('label');
                const checked = SRE_PRESELECTED_DATA.includes(d.rel) ? 'checked' : '';
                label.innerHTML = `<input type="checkbox" class="sre-data-disk" value="${d.rel}" ${checked}> ${d.name} (${d.type})` + ` <span class="sre-disk-size">${humanBytes(d.used_bytes)} used / ${humanBytes(d.size_bytes)}</span>`;
                checklist.appendChild(label);
                dataLabels[d.rel] = label;
            });

            // A disk chosen as parity (or parity-2) can't also be protected -
            // SnapRAID forbids it. Hide it from the checklist and drop any
            // stale checkmark so a save can't silently double-use the disk.
            function syncDiskAvailability() {
                const p1 = paritySel.value;
                const p2 = parity2Sel ? parity2Sel.value : '';
                Object.keys(dataLabels).forEach(rel => {
                    const taken = rel !== '' && (rel === p1 || rel === p2);
                    dataLabels[rel].style.display = taken ? 'none' : '';
                    if (taken) dataLabels[rel].querySelector('input').checked = false;
                });
                // Keep the second-parity selector from offering the same disk
                // as the first (SnapRAID rejects parity and parity-2 on one
                // device).
                if (parity2Sel) {
                    Array.from(parity2Sel.options).forEach(o => {
                        o.disabled = o.value !== '' && o.value === p1;
                    });
                }
            }
            paritySel.addEventListener('change', syncDiskAvailability);
            if (parity2Sel) parity2Sel.addEventListener('change', syncDiskAvailability);
            syncDiskAvailability();

            // If the saved parity path is a raw device, warn the user - it's
            // no longer selectable and SnapRAID can't use it.
            const warnEl = document.getElementById('sre-parity-warning');
            if (warnEl) {
                warnEl.style.display = (SRE_PRESELECTED_PARITY && SRE_PRESELECTED_PARITY.indexOf('/dev/') === 0) ? 'block' : 'none';
            }
        });

        document.getElementById('sre-schedule-select').value = SRE_PRESELECTED_SCHEDULE || 'daily';
        document.getElementById('sre-exclude-custom').value = SRE_CUSTOM_EXCLUDES || '';

        // Custom schedule: friendly day-of-week + time pickers that generate the
        // cron, with an "Advanced" mode for typing cron directly. The pickers
        // are the default; advanced is only needed for non-day-of-week crons.
        const syncDow = document.getElementById('sre-sync-dow');
        const scrubDow = document.getElementById('sre-scrub-dow');
        const syncTime = document.getElementById('sre-sync-time');
        const scrubTime = document.getElementById('sre-scrub-time');
        const syncCronInput = document.getElementById('sre-custom-sync-cron');
        const scrubCronInput = document.getElementById('sre-custom-scrub-cron');
        const advancedChk = document.getElementById('sre-custom-advanced');
        const advancedBox = document.getElementById('sre-custom-advanced-box');
        const syncPreview = document.getElementById('sre-sync-cron-preview');
        const scrubPreview = document.getElementById('sre-scrub-cron-preview');

        function setPickerDays(container, days) {
            container.querySelectorAll('input[type=checkbox]').forEach(cb => { cb.checked = days.includes(cb.value); });
        }
        function updatePreviews() {
            syncPreview.textContent = buildCron(syncDow, syncTime) || '(pick days and a time)';
            scrubPreview.textContent = buildCron(scrubDow, scrubTime) || '(pick days and a time)';
        }
        function toggleAdvanced() {
            const adv = advancedChk.checked;
            advancedBox.style.display = adv ? 'block' : 'none';
            syncDow.style.display = adv ? 'none' : 'flex';
            scrubDow.style.display = adv ? 'none' : 'flex';
            syncTime.style.display = adv ? 'none' : 'inline-block';
            scrubTime.style.display = adv ? 'none' : 'inline-block';
        }
        advancedChk.addEventListener('change', () => {
            if (!advancedChk.checked) {
                // Switching back to the pickers only works if the saved cron is
                // a simple day-of-week expression; otherwise keep advanced mode.
                const sp = cronToPicker(syncCronInput.value);
                const pp = cronToPicker(scrubCronInput.value);
                if (!sp || !pp) {
                    advancedChk.checked = true;
                    alert('That cron can\'t be shown as a simple picker - keep advanced mode or edit the cron.');
                    return;
                }
                setPickerDays(syncDow, sp.days); syncTime.value = sp.time;
                setPickerDays(scrubDow, pp.days); scrubTime.value = pp.time;
            }
            toggleAdvanced();
            updatePreviews();
        });
        syncDow.addEventListener('change', updatePreviews);
        scrubDow.addEventListener('change', updatePreviews);
        syncTime.addEventListener('change', updatePreviews);
        scrubTime.addEventListener('change', updatePreviews);

        // Pre-fill from the saved cron: pickers when it's a simple day-of-week
        // expression, otherwise fall back to advanced mode.
        syncCronInput.value = SRE_CUSTOM_SYNC_CRON || '';
        scrubCronInput.value = SRE_CUSTOM_SCRUB_CRON || '';
        const sp = cronToPicker(SRE_CUSTOM_SYNC_CRON);
        const pp = cronToPicker(SRE_CUSTOM_SCRUB_CRON);
        if (sp && pp) {
            setPickerDays(syncDow, sp.days); syncTime.value = sp.time;
            setPickerDays(scrubDow, pp.days); scrubTime.value = pp.time;
            advancedChk.checked = false;
        } else {
            advancedChk.checked = true;
        }
        toggleAdvanced();
        updatePreviews();

        // Show the custom schedule box only when the Custom option is selected.
        const schedSel = document.getElementById('sre-schedule-select');
        const customBox = document.getElementById('sre-custom-schedule');
        const toggleCustom = () => { customBox.style.display = schedSel.value === 'custom' ? 'block' : 'none'; };
        schedSel.addEventListener('change', toggleCustom);
        toggleCustom();
    }

    function loadBackup() {
        loadBackups(); // refresh the backup list every time the tab opens
    }

    // A valid cron expression is 5 whitespace-separated fields of cron-safe
    // characters (minute hour day-of-month month day-of-week).
    function validCron(expr) {
        const fields = expr.trim().split(/\s+/);
        if (fields.length !== 5) return false;
        return fields.every(f => /^[0-9*\/,-]+$/.test(f));
    }

    // Build a cron expression from the day-of-week checkboxes + time picker.
    // Returns null when no day is selected or the time is empty.
    function buildCron(dowContainer, timeInput) {
        const days = Array.from(dowContainer.querySelectorAll('input:checked')).map(cb => cb.value);
        if (days.length === 0 || !timeInput.value) return null;
        const dow = days.length === 7 ? '*' : days
            .map(d => d === '0' ? 7 : parseInt(d, 10))
            .sort((a, b) => a - b)
            .map(d => d === 7 ? 0 : d)
            .join(',');
        const [hh, mm] = timeInput.value.split(':');
        return `${mm} ${hh} * * ${dow}`;
    }

    // Parse a cron expression back into {days, time} for the pickers, or null
    // if it isn't a simple "minute hour * * day-of-week" expression (e.g. it
    // uses day-of-month or step values, which the pickers can't represent).
    function cronToPicker(cron) {
        const f = (cron || '').trim().split(/\s+/);
        if (f.length !== 5 || f[2] !== '*' || f[3] !== '*') return null;
        if (!/^[0-9,*-]+$/.test(f[4])) return null;
        const days = new Set();
        const addDay = d => days.add(d % 7);
        if (f[4] === '*') {
            for (let d = 0; d < 7; d++) addDay(d);
        } else {
            for (const part of f[4].split(',')) {
                if (part === '*') { for (let d = 0; d < 7; d++) addDay(d); }
                else if (/^\d+$/.test(part)) addDay(parseInt(part, 10));
                else if (/^(\d+)-(\d+)$/.test(part)) {
                    const m = part.match(/^(\d+)-(\d+)$/);
                    const lo = parseInt(m[1], 10), hi = parseInt(m[2], 10);
                    if (hi < lo) return null; // wrapped ranges unsupported
                    for (let d = lo; d <= hi; d++) addDay(d);
                } else return null; // step values like */2 unsupported
            }
        }
        const hh = String(parseInt(f[1], 10) % 24).padStart(2, '0');
        const mm = String(parseInt(f[0], 10) % 60).padStart(2, '0');
        return { days: [...days].map(String), time: `${hh}:${mm}` };
    }

    const saveBtn = document.getElementById('sre-btn-save-setup');
    if (saveBtn) saveBtn.addEventListener('click', () => {
        const parity = document.getElementById('sre-parity-select').value;
        const parity2 = document.getElementById('sre-parity2-select').value;
        const dataDisks = Array.from(document.querySelectorAll('.sre-data-disk:checked')).map(el => el.value);
        const presetExcludes = Array.from(document.querySelectorAll('.sre-exclude-preset:checked')).map(el => el.value);
        const customExcludes = document.getElementById('sre-exclude-custom').value
            .split('\n').map(s => s.trim()).filter(Boolean);
        const excludes = presetExcludes.concat(customExcludes).join(',');
        const schedule = document.getElementById('sre-schedule-select').value;
        const threshold = document.getElementById('sre-threshold-input').value || '50';

        if (!parity) { alert('Choose a parity disk first.'); return; }
        if (parity2 && parity2 === parity) { alert('The second parity disk must be different from the first.'); return; }
        if (dataDisks.length === 0) { alert('Select at least one disk to protect.'); return; }

        // Custom schedule: use the pickers unless advanced mode is on, in which
        // case the raw cron fields win.
        let customSyncCron = '', customScrubCron = '';
        if (schedule === 'custom') {
            if (document.getElementById('sre-custom-advanced').checked) {
                customSyncCron = document.getElementById('sre-custom-sync-cron').value.trim();
                customScrubCron = document.getElementById('sre-custom-scrub-cron').value.trim();
            } else {
                customSyncCron = buildCron(document.getElementById('sre-sync-dow'), document.getElementById('sre-sync-time'));
                customScrubCron = buildCron(document.getElementById('sre-scrub-dow'), document.getElementById('sre-scrub-time'));
                if (!customSyncCron || !customScrubCron) {
                    alert('Pick at least one day and a time for both sync and scrub.');
                    return;
                }
            }
            if (!validCron(customSyncCron) || !validCron(customScrubCron)) {
                alert('Custom schedule needs valid 5-field cron expressions, e.g. "30 3 * * 1,3,5" for sync and "0 4 * * 0" for scrub.');
                return;
            }
        }

        // spread content files across up to 3 of the chosen data disks
        const contentDisks = dataDisks.slice(0, 3);

        const resultEl = document.getElementById('sre-setup-result');
        resultEl.textContent = 'Saving...';

        post('save_setup', {
            parity_path: parity,
            parity2_path: parity2,
            data_disks: JSON.stringify(dataDisks),
            content_disks: JSON.stringify(contentDisks),
            excludes: excludes,
            schedule: schedule,
            custom_sync_cron: customSyncCron,
            custom_scrub_cron: customScrubCron,
            delete_threshold: threshold
        }).then(res => {
            resultEl.textContent = res.ok ? 'Saved. Schedule installed.' : ('Error: ' + (res.error || 'unknown'));
        });
    });

    const importBtn = document.getElementById('sre-btn-import');
    if (importBtn) importBtn.addEventListener('click', () => {
        const path = document.getElementById('sre-import-path').value.trim();
        const resultEl = document.getElementById('sre-import-result');
        resultEl.textContent = 'Importing...';
        post('import_config', { path }).then(res => {
            if (res.ok) {
                resultEl.textContent = 'Imported: parity=' + res.parity + ', data=' + res.data + '. Reloading...';
                setTimeout(() => location.reload(), 1200); // re-render Setup with the imported values
            } else {
                resultEl.textContent = 'Error: ' + (res.error || 'unknown');
            }
        });
    });

    // -------------------------------------------------------------------
    // Alerts
    // -------------------------------------------------------------------
    function loadAlerts() {
        // Settings are pre-filled server-side into SRE_ALERTS; just apply them.
        document.querySelectorAll('#sre-alert-toggles input[type=checkbox], #sre-health-toggles input[type=checkbox]').forEach(cb => {
            cb.checked = SRE_ALERTS[cb.dataset.alert] === '1';
        });
        document.querySelectorAll('.sre-alert-num').forEach(inp => {
            inp.value = SRE_ALERTS[inp.dataset.alert] || '';
        });
    }

    const saveAlertsBtn = document.getElementById('sre-btn-save-alerts');
    if (saveAlertsBtn) saveAlertsBtn.addEventListener('click', () => {
        const payload = {};
        document.querySelectorAll('#sre-alert-toggles input[type=checkbox], #sre-health-toggles input[type=checkbox]').forEach(cb => {
            payload[cb.dataset.alert] = cb.checked ? '1' : '0';
        });
        document.querySelectorAll('.sre-alert-num').forEach(inp => {
            payload[inp.dataset.alert] = inp.value || '';
        });
        const resultEl = document.getElementById('sre-alerts-result');
        resultEl.textContent = 'Saving...';
        post('save_alerts', payload).then(res => {
            resultEl.textContent = res.ok ? 'Saved.' : ('Error: ' + (res.error || 'unknown'));
        });
    });

    const testNotifyBtn = document.getElementById('sre-btn-test-notify');
    if (testNotifyBtn) testNotifyBtn.addEventListener('click', () => {
        const resultEl = document.getElementById('sre-alerts-result');
        resultEl.textContent = 'Sending...';
        post('test_notify').then(res => {
            resultEl.textContent = res.ok ? 'Test notification sent.' : ('Error: ' + (res.error || 'unknown'));
        });
    });

    // -------------------------------------------------------------------
    // Config backup / restore
    // -------------------------------------------------------------------
    function loadBackups() {
        const list = document.getElementById('sre-backup-list');
        if (!list) return;
        post('list_backups').then(rows => {
            if (!Array.isArray(rows) || rows.length === 0) {
                list.innerHTML = '<span style="opacity:.6">No backups yet. Click "Backup now" to snapshot the current config.</span>';
                return;
            }
            list.innerHTML = rows.map(b => {
                const dt = new Date(b.date * 1000);
                return `<div class="sre-backup-item">
                    <span>${esc(b.name)} <span style="opacity:.6">(${humanBytes(b.size)}, ${dt.toLocaleString()})</span></span>
                    <span class="sre-backup-actions">
                        <button class="sre-btn sre-btn-warn sre-restore-backup" data-name="${esc(b.name)}">Restore</button>
                        <button class="sre-btn sre-delete-backup" data-name="${esc(b.name)}">Delete</button>
                    </span>
                 </div>`;
            }).join('');
            Array.from(list.querySelectorAll('.sre-restore-backup')).forEach(btn => {
                btn.addEventListener('click', () => {
                    if (!confirm('Restore this backup? This overwrites the current snapraid.conf and settings.ini.')) return;
                    btn.textContent = 'Restoring…';
                    post('restore_config', { name: btn.dataset.name }).then(res => {
                        const resultEl = document.getElementById('sre-backup-result');
                        resultEl.textContent = res.ok ? 'Restored.' : ('Error: ' + (res.error || 'unknown'));
                        loadBackups();
                    });
                });
            });
            Array.from(list.querySelectorAll('.sre-delete-backup')).forEach(btn => {
                btn.addEventListener('click', () => {
                    if (!confirm('Delete this backup permanently? This cannot be undone.')) return;
                    btn.textContent = 'Deleting…';
                    post('delete_backup', { name: btn.dataset.name }).then(res => {
                        const resultEl = document.getElementById('sre-backup-result');
                        resultEl.textContent = res.ok ? 'Backup deleted.' : ('Error: ' + (res.error || 'unknown'));
                        loadBackups();
                    });
                });
            });
        });
    }

    const backupNowBtn = document.getElementById('sre-btn-backup-now');
    if (backupNowBtn) backupNowBtn.addEventListener('click', () => {
        const resultEl = document.getElementById('sre-backup-result');
        resultEl.textContent = 'Backing up...';
        post('backup_config', {}).then(res => {
            resultEl.textContent = res.ok ? ('Backup saved: ' + res.name) : ('Error: ' + (res.error || 'unknown'));
            loadBackups();
        });
    });

    // -------------------------------------------------------------------
    // Recover
    // -------------------------------------------------------------------
    const esc = s => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    function loadRecover() {
        const list = document.getElementById('sre-problem-list');
        const summaryEl = document.getElementById('sre-problem-summary');
        const fixAllBtn = document.getElementById('sre-btn-fix-all');
        list.textContent = 'Checking...';
        post('get_problems').then(problems => {
            if (!Array.isArray(problems) || problems.length === 0) {
                list.textContent = 'No known problems. Run a scrub or a full check to verify the array.';
                if (summaryEl) summaryEl.style.display = 'none';
                fixAllBtn.style.display = 'none';
                return;
            }
            fixAllBtn.style.display = 'inline-block';
            const totalSize = problems.reduce((s, p) => s + (p.size || 0), 0);
            const unrecoverable = problems.filter(p => p.reason === 'unrecoverable').length;
            if (summaryEl) {
                summaryEl.style.display = 'block';
                summaryEl.textContent = `${problems.length} damaged file(s)${unrecoverable ? `, ${unrecoverable} unrecoverable` : ''} - ~${humanBytes(totalSize)} to restore.`;
            }
            list.innerHTML = problems.map(p =>
                `<div class="sre-problem-item">
                    <span>${esc(p.path)} <span style="opacity:.6">(${esc(p.disk)}${p.reason === 'unrecoverable' ? ', unrecoverable' : ''})</span></span>
                    <button class="sre-btn sre-btn-warn sre-fix-file" data-path="${esc(p.path)}">Restore this file</button>
                 </div>`
            ).join('');
            document.querySelectorAll('.sre-fix-file').forEach(btn => {
                btn.addEventListener('click', () => {
                    btn.textContent = 'Restoring\u2026';
                    post('fix_file', { path: btn.dataset.path }).then(() => loadRecover());
                });
            });
        });

        // If a full check is already running, resume polling it.
        post('get_check_state').then(st => {
            if (st.status === 'running') {
                const progressEl = document.getElementById('sre-check-progress');
                progressEl.style.display = 'block';
                progressEl.textContent = 'Full check in progress...' + (st.progress ? ` ${st.progress}%` : '');
                runCheckBtn.disabled = true;
                runCheckBtn.textContent = 'Checking...';
                if (cancelCheckBtn) cancelCheckBtn.style.display = 'inline-block';
                setTimeout(pollCheckState, 3000);
            }
        });
    }

    const fixAllBtn = document.getElementById('sre-btn-fix-all');
    if (fixAllBtn) fixAllBtn.addEventListener('click', () => {
        fixAllBtn.textContent = 'Restoring\u2026';
        post('fix_all').then(() => loadRecover());
    });

    const runCheckBtn = document.getElementById('sre-btn-run-check');
    const cancelCheckBtn = document.getElementById('sre-btn-cancel-check');
    function pollCheckState() {
        post('get_check_state').then(st => {
            const progressEl = document.getElementById('sre-check-progress');
            if (st.status === 'running') {
                progressEl.style.display = 'block';
                progressEl.textContent = 'Full check in progress...' + (st.progress ? ` ${st.progress}%` : '');
                if (cancelCheckBtn) cancelCheckBtn.style.display = 'inline-block';
                setTimeout(pollCheckState, 3000);
            } else {
                progressEl.style.display = 'none';
                if (cancelCheckBtn) cancelCheckBtn.style.display = 'none';
                runCheckBtn.disabled = false;
                runCheckBtn.textContent = 'Run full check';
                loadRecover();
            }
        });
    }
    if (runCheckBtn) runCheckBtn.addEventListener('click', () => {
        runCheckBtn.disabled = true;
        runCheckBtn.textContent = 'Checking...';
        post('run_check', {}).then(() => pollCheckState());
    });
    if (cancelCheckBtn) cancelCheckBtn.addEventListener('click', () => {
        post('cancel_check', {}).then(() => pollCheckState());
    });
    // -------------------------------------------------------------------
    // ? Help tooltips (Sync vs Scrub)
    // -------------------------------------------------------------------
    var helpContent = {
        sync: "<h4>Sync</h4><p>A <b>sync</b> updates the parity data to match the current contents of your data disks. When files are added, changed, or deleted, parity becomes out of date; a sync brings it back in line.</p><p><b>When:</b> run after adding, changing, or deleting a significant number of files. It scans the data disks and rewrites parity.</p>",
        scrub: "<h4>Scrub</h4><p>A <b>scrub</b> verifies the integrity of your stored data by re-reading a percentage of it and comparing against parity. It detects bit-rot and silent corruption that a sync would not catch.</p><p><b>When:</b> run periodically (e.g. monthly), often with a low percentage per run so that eventually every block is checked.</p>",
        history: "<h4>History</h4><p>This lists every completed Sync and Scrub run, newest first. Each row shows when it ran, what type it was, whether it succeeded, and key numbers (files added/removed/updated for a Sync; problems found for a Scrub).</p><p>Click a row to open that run's full log. The last 100 runs are kept; history is stored with your settings and survives reboots.</p>",
    };
    var helpEl = document.getElementById('sre-help-tooltip');
    function showHelp(key) {
        if (!helpEl) return;
        helpEl.innerHTML = helpContent[key] || '';
        helpEl.style.display = 'block';
    }
    function hideHelp() { if (helpEl) helpEl.style.display = 'none'; }
    document.querySelectorAll('.sre-help').forEach(function (h) {
        var key = h.getAttribute('data-help');
        h.addEventListener('click', function (ev) {
            ev.stopPropagation();
            var r = h.getBoundingClientRect();
            showHelp(key);
            helpEl.style.left = (r.left + r.width + 10) + 'px';
            helpEl.style.top = (r.top) + 'px';
        });
    });
    document.addEventListener('click', function () { hideHelp(); });
})();
