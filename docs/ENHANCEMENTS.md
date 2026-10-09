# SnapUnraid — Enhancement Checklist

Findings from a codebase review of the plugin (v2026.10.09). Each item cites the
code it builds on so it can be picked up independently. Effort/impact are
estimates, not commitments.

Legend: **Effort** S/M/L · **Impact** low/med/high · `- [ ]` = not started.

---

## Quick wins (high value, low effort)

- [ ] **Surface scrub coverage on the Dashboard** — *Effort S · Impact high*
  - `scripts/status.sh` already parses and caches `snapraid_scrub_oldest_days`,
    `snapraid_scrub_median_days`, `snapraid_scrub_newest_days`, but
    `snapunraid.js` never reads them (it only uses `snapraid_parity_age_days`).
  - Add a "Coverage: newest Xd / median Yd / oldest Zd" line to the array-status
    summary. No backend change needed for the display itself.

- [ ] **Expose scrub percentage / older-than (and blocksize) in Setup** — *Effort S · Impact high*
  - `scripts/scrub.sh:55-56` reads `SCRUB_PERCENT` (default 12) and
    `SCRUB_OLDER_THAN` (default 10); `scripts/genconfig.sh:95` hardcodes
    `blocksize 256`. None are editable from the UI today.
  - Add a "Scrub" card (percentage per run, older-than days) and an Advanced
    blocksize field; persist via `save_setup` in `ajax.php` and emit in
    `genconfig.sh`.

- [ ] **Show the actual error text on the Dashboard** — *Effort S · Impact med*
  - `state.json` already carries `sync_last_error` / `scrub_last_error`
    (`scripts/sync.sh`, `scripts/scrub.sh`), but the UI shows generic text.
  - Render the error inline (reuse the existing log modal) so a failure is
    diagnosable without opening the log.

- [ ] **Expose content-disk placement** — *Effort S · Impact med*
  - `snapunraid.js:712` silently spreads content files across the first 3
    protected disks (`dataDisks.slice(0, 3)`); `CONTENT_DISKS` is already a
    first-class setting (`ajax.php:169`, `genconfig.sh:19`).
  - Add a max-3 multi-select so content files don't land on unexpected disks.

---

## Medium

- [ ] **Configurable alert cooldown + large-deletion notification** — *Effort M · Impact med*
  - Health-alert dedup is a fixed 24h (`sre_alert_once` in `scripts/common.sh`).
  - Add an optional "sync made a large change" notification mirroring the
    confirmation threshold (`DELETE_THRESHOLD_COUNT`).

- [ ] **Verify a file after restore** — *Effort M · Impact med*
  - `scripts/recover.sh fix` reports exit code only; no confirmation the file is
    good.
  - Add a follow-up `snapraid check -d <disk> -f <rel>` (or a "Verify this file"
    button) so recovery is proven, not assumed.

- [ ] **Scheduling flexibility / collision avoidance** — *Effort M · Impact med*
  - Sync and scrub are fixed pairings in `scripts/install_cron.sh`.
  - Consider "scrub after every Nth successful sync", "skip while an Unraid
    parity check is running", or a quiet-hours guard.

- [ ] **Harden `ajax.php`** — *Effort M · Impact med*
  - The front-end sends `csrf_token` to satisfy nginx, but `ajax.php` never
    validates it server-side.
  - `sre_cancel_operation` / `cancel_pending` hardcode
    `/var/local/snapunraid/state.json` instead of the `SRE_STATE_FILE` override
    the rest of `common.sh` honors.
  - Add an explicit token check and route both handlers through the shared path
    constant (also makes them testable in the offline suite).

- [ ] **Persist coverage / missing-split fields in history** — *Effort S · Impact med*
  - `sre_append_history` writes `bad_files` for scrubs but not coverage or the
    missing-vs-real split. Needed to support the coverage trends below.

---

## Larger / architectural

- [ ] **Trend history (sparklines)** — *Effort L · Impact med*
  - `history.jsonl` already accumulates every run; add parity-age, scrub-
    coverage and files-changed trends on Dashboard/History. Front-end charting
    over existing data (plus the history fields above).

- [ ] **Unraid-native event integration** — *Effort L · Impact med*
  - Only `event/started` exists. Hooking `stopping`, mover and parity-check
    events would let the plugin pause during maintenance and sync after array
    start, reducing "disk dropped mid-operation" exposure.

- [ ] **Opt-in auto-update of the SnapRAID binary** — *Effort M · Impact low*
  - The version check + cached GitHub lookup already exist
    (`scripts/install_snapraid.sh --check`); add an opt-in auto-apply or
    automatic pinned-fallback update.

---

## Suggested order

1. Scrub coverage on the Dashboard
2. Scrub percentage / older-than / blocksize in Setup
3. Show error text on the Dashboard

These three are small, self-contained, and use data or inputs the backend
already has — the highest value per unit of work, and all directly visible on
the Dashboard.
