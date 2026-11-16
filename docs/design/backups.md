# Backup design

Part of the Nightshift plan (`docs/PLAN.md`). This file owns what gets backed up, how, when, and how restores are proven. Household backups are separate and planned privately.

## What gets backed up

**Databases:** `pg_dumpall --globals-only` plus `pg_dump -Fc` for each database (`app-postgres` and `nightshift-db`).
- Dumps run with `docker exec` as each database's owner role, and are written to `/var/backups/pg`.
- **Consistent counts:** row counts are taken inside the same snapshot as the dump. A `REPEATABLE READ` transaction calls `pg_export_snapshot()`, counts the rows, and `pg_dump --snapshot=<id>` uses that snapshot.
- **Verified before keeping:** each dump is written to `f.tmp`, checked with `docker exec -i <postgres> pg_restore --list < f.tmp` (the host client is older than Postgres 18), then renamed.

**Config:** `/etc/nightshift/` (secrets and config).

**Not backed up:**
- Loki and Prometheus data;
- Grafana's database (dashboards are provisioned from the repo);
- live database directories.

## The unit

**`nightshift-backup.service`:**
- **Conditions:** `RequiresMountsFor=/mnt/backup`, `ConditionACPower=true`, `ExecStartPre=/usr/bin/mountpoint -q /mnt/backup`.
- **`OnFailure=`** points at a notify unit.
- **`run.sh`:**
  - starts with `umask 077`;
  - takes `flock /run/nightshift/restic.lock`, so restic jobs never overlap.
- **Steps:**
  1. Ping Healthchecks.io `/start`.
  2. Dumps.
  3. `restic backup --retry-lock 15m`.
  4. Write `nightshift_backup_last_success_timestamp_seconds` and `nightshift_backup_bytes`.
  5. Ping success.

**Timers:**
- 03:00 daily (`OnCalendar=*-*-* 03:00`).
- A 05:30 catch-up run (`OnCalendar=*-*-* 05:30`, `Persistent=true`) that exits if the last success was under 20 hours ago.

**Healthchecks.io check:** a **cron check**, `0 3 * * *` with time zone `America/Los_Angeles` and a 3-hour grace. A skipped unit never pings `/fail`, so the check has to notice the silence. Without the time zone, it reads 3 a.m. as UTC.

## Maintenance (Wednesdays, away from Sunday's reboot)

All of these take the restic lock:
- **Weekly:** `restic forget --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune --retry-lock 15m`.
- **Monthly:** `restic check --read-data-subset=$(date +%-m)/12`, which reads the whole repo over a year.
- **Monthly automated restore test** (`restore-test.sh`):
  1. `restic restore latest --include /var/backups/pg` into `/var/tmp` (on Debian 13, `/tmp` is a RAM disk).
  2. Restore into a throwaway `--network none` Postgres.
  3. Compare row counts with the ones recorded at dump time.
  4. Write `nightshift_restore_test_last_success_timestamp_seconds`.

## The drive

- **fstab:** `UUID=<uuid> /mnt/backup ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2`.
- **Health:** a weekly `smartctl -d sat -H`.
- **Check:** confirm the server still boots with the drive unplugged.
- **Location:** the drive is kept with the laptop, so assume a thief takes both. It's a single point of failure until there's an off-site copy.

## Keys

- **The restic password** lives in `/etc/nightshift/secrets/restic/` (0400) **and** in my password manager, plus a printed copy. Losing it means losing the backups.
- **What restic protects:** only backups stolen *without* the laptop, because the password is on the laptop. After a theft, treat it as burned (`host-ops.md`).

## Before any household data

- **Off-site repo:** a second, off-site restic repo (for example Backblaze B2, with a key limited to one bucket, and object lock).
- **Full restore test:** one that also checks file checksums.
- **Separate household repo:** household data gets its own repo, whose password lives only on the household volume.

## Alerts (`monitoring.md`)

- Last backup older than 26 hours, or the metric missing.
- Last restore test older than 40 days.
- Backup drive over 80% full, missing, or read-only.
- *(After Dec 13)* Backup size changing by more than 30%, a possible ransomware sign.
