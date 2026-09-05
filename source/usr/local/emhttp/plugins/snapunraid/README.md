SnapUnraid installs SnapRAID (a prebuilt binary — no compiler required) and adds a
simple webGUI to the Unraid Settings → User Utilities menu for snapshot-based parity
and protection. Use the **Dashboard** for at-a-glance status, **Setup** to pick a
dedicated parity disk and the data disks to protect (plus schedule, excludes, and a
deletion-safety threshold), and **Recover** to rebuild a failed or removed disk from
parity.

- **Sync** updates parity after files are added, changed, or deleted.
- **Scrub** periodically verifies data integrity and detects bit-rot / silent
  corruption.
- Sync/Scrub can run on a schedule via cron.

Notes: SnapRAID snapshots your data disks and stores parity separately (it does not
mirror files like an md parity array). A dedicated parity disk around the size of your
largest data disk is recommended. The first-time setup takes a few minutes; the initial
sync builds parity across your chosen data disks.
