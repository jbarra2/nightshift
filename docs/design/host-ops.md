# Host operations design

Part of the Nightshift plan (`docs/PLAN.md`). This file owns the server itself:
- disks, BIOS and Secure Boot;
- how changes reach the server;
- shared plumbing, boot ordering and maintenance;
- emergency access and theft response.

Power handling is in `power.md`. The install itself is `docs/runbooks/reinstall-server.md`.

## Disk encryption (decided: none for now)

See `docs/decisions/0002-disk-encryption.md`.

**Why:** the server has to come back on its own after outages and reboots.
- Encryption plus unattended reboots means TPM auto-unlock (Clevis). That brings update holds, re-binding after boot-chain updates, boot hardening, and the risk of waiting at a passphrase prompt.
- Even then, a skilled thief with the powered-off laptop could still get the key.

**What it means:** anyone who takes the laptop can read the disk. I accept this for my own portfolio projects because:
- every secret on the server is revocable (theft response below);
- the Anthropic workspace has a spend limit.

**What it doesn't protect:** restic encryption protects backups only if they're stolen **without** the laptop. The restic password is on the laptop.

**Household data** (after Dec 13) gets its own encrypted volume and its own backups, planned in private notes.

## Disk layout (LVM, volume group `nightshift-vg`)

| Volume | Size | Mount | Use | When |
|---|---|---|---|---|
| root (ext4) + `swap_1` | 300 GB total (~279 GiB) | `/` | OS, Docker, databases, app data | Install |
| `mon-prometheus` (ext4) | 25 GB | `/srv/nightshift/prometheus` | Prometheus data | Phase 2 |
| `mon-loki` (ext4) | 15 GB | `/srv/nightshift/loki` | Loki data (Target) | Phase 2 |
| `household` (LUKS + ext4) | as needed | `/srv/household` | Samba and Immich data | After Dec 13 |
| free | ~600 GiB | — | Growing volumes later | — |

- **fstab** for the monitoring volumes: `UUID=… <mount> ext4 defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2`.
- **Fail loudly if a volume isn't mounted:** each data folder (for example `/srv/nightshift/prometheus/data`) exists only on its volume, and containers mount it with `create_host_path: false`. If a volume isn't mounted, the container fails instead of writing onto root. `start-all.sh` also skips the stack and alerts.
- **Encrypted swap with a random key** (Phase 1; needs nobody at boot):
  - `/etc/crypttab`: `swap /dev/nightshift-vg/swap_1 /dev/urandom swap,cipher=aes-xts-plain64,size=512`
  - fstab: `/dev/mapper/swap none swap sw 0 0`
  - `RESUME=none` in `/etc/initramfs-tools/conf.d/resume`, then `update-initramfs -u`
- **No core dumps on disk:** `Storage=none` in `/etc/systemd/coredump.conf`.
- **`/boot`:** the installer makes about 1 GB. Trixie wants at least 768 MB with about 300 MB free. The maintenance gate requires 300 MB free, and `nightshift_boot_free_bytes` is a metric.
- **The chaos disk** is a 512 MB image file at `/srv/nightshift/chaos-disk.img`, loop-mounted at `/srv/nightshift/chaos-disk` (`oncall.md`).

## Secure Boot and firmware

**Secure Boot stays on.** With it on, the Debian kernel refuses unsigned kernel modules.

**The certificate that matters is "Microsoft UEFI CA 2023".** New shims are signed only with it, because the 2011 CA expired in June 2026.
- **Check it before the first upgrade:** `sudo mokutil --db | grep -F 'Microsoft UEFI CA 2023'`.
- **Use the exact name.** "Windows UEFI CA 2023" and "Microsoft Option ROM UEFI CA 2023" are different certificates.

**Debian already reduces the risk:**
- shim-signed 1.48 (May 2026) ships a dual-signed shim that includes the 2023 CA;
- its preinst script tries to verify that the new shim will boot on this machine;
- trixie has 1.51~1+deb13u1.

**If the certificate is missing:**
1. Hold the shim packages: `sudo apt-mark hold shim-signed shim-helpers-amd64-signed`. A dpkg hold blocks manual apt runs and unattended-upgrades alike.
2. The daily check writes `nightshift_shim_hold_pending`: 1 when a held package has a newer version, which adds a "Needs you" line.
3. Try a firmware fix by hand: `sudo fwupdmgr security`, then apply any db, KEK or dbx update fwupd offers. After a BIOS update, use ThinkPad Setup → Security → Secure Boot → **Restore Factory Keys**, then re-apply dbx.
4. LVFS lists only ME and EC firmware for the T480s, so the certificate may never arrive that way.
5. If it never arrives, decide by **Dec 13** between keeping the hold and turning Secure Boot off (D-10). A permanent hold also blocks shim security fixes.

**Firmware updates are done by hand only, when I'm home.** Never from a script or timer.

## BIOS settings

- **Supervisor password**, stored in my password manager. It can't be reset without a new system board.
- **No power-on or hard-disk password.** Either would block unattended boot.
- **Power On with AC Attach:** Enabled.
- **Intel AMT:** Disabled, if present.
- **Intel VT-d:** Enabled. Then confirm `/sys/bus/thunderbolt/devices/domain0/iommu_dma_protection` reads 1.
- **Set these last, after the install:**
  - Boot Order Lock: Enabled.
  - F12 boot menu: Disabled.
  - Bottom Cover Tamper Detection: Enabled. After the cover is opened, the next boot needs the supervisor password, which is the alarm.

Without disk encryption, these are what slow down someone who has a few minutes and a USB stick.

## Laptop as a server

- **Lid and sleep:**
  - `HandleLidSwitch=ignore` (plus `...ExternalPower` and `...Docked`);
  - mask the sleep, suspend and hibernate targets.
- **Network:**
  - Wired, on the T480s's **built-in RJ-45 port**.
  - The `/etc/network/interfaces` stanza is `auto`, not the installer's `allow-hotplug`.
  - A static IP on the host equal to the router's DHCP reservation, or outside the DHCP pool.
- **Resolvers:** the router and `1.1.1.1`. The server never uses its own Pi-hole.
- **TLP:** battery thresholds at 75/80, and the backup drive on `USB_DENYLIST`.
- **Health:**
  - alert on battery health below 60%;
  - check monthly for swelling (a bulging cover, a lifting touchpad);
  - watch SMART;
  - keep the vents clear and use a stand.
- **Kernel:**
  - `kernel.panic = 10`;
  - `RuntimeWatchdogSec=30s` if `wdctl` shows a hardware watchdog.
- **Emergency console:** with no root password, Debian's emergency and rescue targets give no shell by default (Debian bug #952450). Add this drop-in for both `emergency.service` and `rescue.service`:

  ```ini
  # /etc/systemd/system/{emergency,rescue}.service.d/10-locked-root.conf
  [Service]
  Environment=SYSTEMD_SULOGIN_FORCE=1
  ```

  Test it once: GRUB `e` → append `systemd.unit=emergency.target`. Without disk encryption this adds no exposure, because anyone at the keyboard could already edit the boot entry.

## Server-side state

These are the only things that don't come from the repo:
- **`/etc/nightshift/secrets/<consumer>/`:**
  - created by `host/setup/secrets-init.sh`, which reads values with `read -rs` and never from arguments;
  - per-service owners, files 0400, directories 0750;
  - a daily host check flags anything readable by others.
- **`/etc/nightshift/` config:** `power.conf`, `maintenance.conf`, `lan.conf` and `allowed_signers`.
- **`/etc/nightshift/targets/`** (deferred).
- **`/var/lib/nightshift/`:** deploy state, events, metrics and `update.last`.
- **`/srv/nightshift/`:** the monitoring volumes and the chaos disk.
- **Host config written once** by `host/setup/*.sh`.

## How changes reach the server

**Signing (decided, D-8):** a dedicated SSH signing key on Windows.

**Keys:**
- **The signing key:**
  - `ssh-keygen -t ed25519 -f %USERPROFILE%\.ssh\nightshift_signing -C nightshift-signing`, with a strong passphrase;
  - **never `ssh-add` it.** Every signature then asks for the passphrase, so no other process on Windows can sign quietly. `ssh-add -l` must never list it.
- **The login key** (`nightshift_ed25519`) is separate. Keep it out of ssh-agent too, so nothing on Windows can quietly SSH in.

**Git setup (Phase 0):**
- In the repo: `git config gpg.format ssh`, `git config user.signingkey ~/.ssh/nightshift_signing.pub`, and `git config commit.gpgsign false`.
- Sign explicitly with `-S`, from a terminal (the passphrase prompt needs one).
- The principal in `/etc/nightshift/allowed_signers` must match my commit email.

**Workflow (`main` + `develop`):**
- **`main`** is the source of truth, and the server deploys only from it.
- **`develop`** is where tested work rests before release. CI runs on it, but nothing deploys from it.
- **Feature branches** (`feature/<topic>`) come off `develop`. Claude Code and I commit there (unsigned is fine) and merge them into `develop`.
- **Release:** after testing on `develop`, I run `git switch main && git merge --no-ff -S develop` (one passphrase prompt) and `git push origin main`, then bring `develop` up to date with `git switch develop && git merge --ff-only main`.
- **Hotfix:** branch off `main`, merge it back into `main` with `--no-ff -S`, then merge `main` into `develop`.
- **Renovate** targets `develop`, and its updates reach `main` with the next release.
- **Never merge on GitHub.** GitHub signs web merges with its own key, which the server rejects.
- **Never fast-forward `main`.** Every first-parent commit on `main` must be a signed merge (or a signed commit). The local `pre-push` hook checks this before anything leaves Windows.

**`sudo nightshift-update`** (installed at `/usr/local/sbin/nightshift-update`):
1. Take the deploy lock, and create `/run/nightshift/deploy/deploy.frozen`.
2. `git -C /opt/nightshift fetch -q origin main`.
3. Verify every **first-parent** commit in `$(cat /var/lib/nightshift/update.last)..origin/main` with `git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=/etc/nightshift/allowed_signers verify-commit`. Any failure stops the update.
   - A signed merge commit covers the whole tree it produces, so the unsigned `develop` and feature commits underneath it don't need signatures.
4. **Review gate:**
   - show `git log --first-parent --format='%h %G? %an %s'` for the range;
   - show `git diff --stat` and the full diff for `host/`, `policy/` and `stacks/{platform,monitoring,edge,postgres}`;
   - continue only if I type the new short SHA.
5. `git merge --ff-only`, then `install -D -m 0755` the scripts into `/usr/local/lib/nightshift/` and the units into `/etc/systemd/system/`. `install` unlinks first; never use `cp` over a script that might be running.
6. `systemctl daemon-reload`, write the new HEAD to `update.last`, and unfreeze.

**Notes:**
- **Starting point:** `update.last` is seeded at install with a commit hash I check by hand.
- **Ownership:** `/opt/nightshift` is root-owned, and units only run the installed copies.
- **Sudo, not the docker group:** my user isn't in `docker`, and sudo needs a password. Never set `safe.directory='*'`.
- **Applying infra changes** isn't automatic. After an update, `sudo nightshift-apply <stack>` validates the stack and runs `up` for it (with recreate). The reconcile timer never does this.

## Shared plumbing

- **`/etc/tmpfiles.d/nightshift.conf`** creates at every boot:
  - `/run/nightshift/` (0755, root), which also holds `restic.lock` and the `maintenance` flag;
  - `/run/nightshift/deploy/` (0750, shared with the deploy container), with `deploy.lock` created once and never deleted;
  - `/run/nightshift/power/` (0700, root only);
  - `/var/lib/nightshift/{deploy,events,metrics}`.
- **One deploy lock:** every Docker writer uses `flock -w 60 /run/nightshift/deploy/deploy.lock`. `host/lib/lock.sh` exports the open fd, so child scripts don't re-lock. Start paths skip if the lock is busy; stop paths proceed and log it.
- **One metrics directory, `/var/lib/nightshift/metrics`:**
  - node_exporter reads it: `ARGS="--collector.textfile.directory=/var/lib/nightshift/metrics"` in `/etc/default/prometheus-node-exporter`;
  - `write_metric()` writes a temp file in the same directory, `chmod 0644`, then `mv`s it to `<writer>.prom`, one file per writer;
  - the deploy service writes to `/var/lib/nightshift/deploy/metrics/`, and a root timer copies its validated `nightshift_deploy_*` lines in.
- **Mount directories, not single files** (long syntax, `create_host_path: false`). Compose file `secrets:` are the exception; after rotating one, recreate that service.
- **Validate every value before use in Bash.** For example, `[[ $v =~ ^[0-9]{1,6}$ ]] || exit 1` before any arithmetic, because `[[ -gt ]]` and `$(( ))` can run code hidden in a value. IDs from APIs must match a strict pattern.

## Boot ordering

```ini
# nightshift-stacks.service
[Unit]
Description=Nightshift ordered stack start/stop
Wants=docker.service network-online.target
After=docker.service network-online.target nightshift-lanblock.service nightshift-chaos-reset.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/local/lib/nightshift/start-all.sh
ExecStop=/usr/local/lib/nightshift/stop-all.sh
TimeoutStartSec=20min
TimeoutStopSec=10min
[Install]
WantedBy=multi-user.target
```

- **`Wants=`, not `Requires=`:** a Docker package upgrade doesn't stop every stack (live-restore keeps containers running).

**`start-all.sh`** enforces its **own 15-minute deadline**, because a start that times out counts as failed and the next shutdown then skips `ExecStop`:
1. Hold the deploy lock for the whole run.
2. Create any missing networks from `networks.tsv`.
3. Check the monitoring mounts.
4. Bring up each stack once, in order (monitoring → databases → platform → apps → edge), with `timeout` around each `up --wait --wait-timeout 120 --no-recreate`. Apps start from their validated state files (`deploy.md`).
5. Retry only the stacks that failed, while time is left.
6. **Always** write `nightshift_stack_up{stack}`, `nightshift_boot_complete_timestamp_seconds` and `/run/nightshift/deploy/boot-complete`, then exit 0.

The 20-minute timeout on the unit is only a backstop.

**`stop-all.sh`:**
1. Create `deploy.frozen`.
2. `docker compose -p nightshift-chaos stop`. An explicit stop survives reboots.
3. Stop the rest in reverse order, with a time budget per stack (totaling under 9 minutes). Databases get `stop_grace_period: 120s`.

**`nightshift-chaos-reset.service`** (`Before=nightshift-stacks.service`, oneshot): runs every chaos revert idempotently at boot, because the reverts scheduled with `systemd-run` don't survive a reboot (`oncall.md`).

**Reconcile, every 15 minutes:**
```ini
# nightshift-reconcile.service
[Unit]
Requisite=nightshift-stacks.service
After=nightshift-stacks.service docker.service
ConditionPathExists=/run/nightshift/deploy/boot-complete
ConditionPathExists=!/run/nightshift/deploy/deploy.frozen
ConditionPathExists=!/run/nightshift/maintenance
[Service]
Type=oneshot
ExecStart=/usr/local/lib/nightshift/start-all.sh --reconcile
TimeoutStartSec=10min
# nightshift-reconcile.timer: OnBootSec=30min, OnUnitInactiveSec=15min
```
- It only starts containers that are missing (`--no-recreate`).
- It skips `nightshift-chaos`, and exits if the system is `stopping`.
- **Drift:** a metric compares each container's `com.docker.compose.config-hash` with the file's, and the handoff lists pending changes for `nightshift-apply`.

**Household** starts from its own `nightshift-household.service` (`RequiresMountsFor=/srv/household`), which the unlock script starts (planned privately).

**Docker major upgrades** follow `docs/runbooks/docker-major-upgrade.md`, which starts with `systemctl stop nightshift-stacks`.

## Weekly maintenance window (`nightshift-maintenance.timer`, Sunday 4:30 a.m.)

1. Take the deploy lock, and create `deploy.frozen` and `/run/nightshift/maintenance`.
2. Create a 30-minute silence for `category="site-down"` alerts.
3. Update only Docker's packages, within their pinned major versions:
   `DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install --only-upgrade -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin`
4. If `docker-ce` or `containerd.io` changed, recreate the socket proxies and the deploy service (`up -d --no-deps --force-recreate`), then smoke-test `/_ping` through each proxy. Socket mounts can go stale after a daemon update.
5. Run `docker image prune -f` (dangling images only).
6. **Reboot only if one is needed and every check passes.**
   - **Needed:** `/var/run/reboot-required` exists, or the running kernel isn't the newest one in `/boot`.
   - **Checks:**
     - `AUTO_REBOOT=true` in `/etc/nightshift/maintenance.conf` (set it to false before any trip; the dates stay out of the repo);
     - `/boot` has at least 300 MB free;
     - `dpkg --audit` is empty;
     - AC is on and the battery is at least 50%;
     - the backup and chaos units are inactive;
     - the newest initramfs exists.
   - **Otherwise** post `reboot deferred: <reason>`.
   - The reboot is `systemctl reboot`, so it goes through the ordered stop.
7. Remove the flags and release the lock.

**Docker pinning,** in `/etc/apt/preferences.d/docker`: pin the major version installed at setup for each of these, and make the deploy image use the same Compose version (`start-all.sh` alerts on a mismatch):

```
Package: docker-ce docker-ce-cli docker-ce-rootless-extras
Pin: version 5:29.*
Pin-Priority: 1001

Package: docker-compose-plugin
Pin: version <major>.*
Pin-Priority: 1001

Package: containerd.io
Pin: version <major>.*
Pin-Priority: 1001
```

**Unattended-upgrades:** `Unattended-Upgrade::Automatic-Reboot "false";`, plus `Dpkg::Options {"--force-confdef";"--force-confold";}`. SSH settings live in `sshd_config.d/` drop-ins, never in the main conffile.

## Daily host checks

One timer, writing `/var/lib/nightshift/metrics/host-daily.prom`:
- `nightshift_apt_security_pending`
- `nightshift_dpkg_audit_problems`
- `nightshift_unattended_upgrades_last_success_timestamp_seconds`
- `nightshift_reboot_required`
- `nightshift_shim_hold_pending`
- `nightshift_boot_free_bytes`
- `nightshift_secret_perms_bad`, from `find /etc/nightshift/secrets -type f -perm /0077`

## Theft and compromise response

**`docs/runbooks/laptop-stolen.md`** (Phase 1, before the first token goes on the server; practice one revocation):
- It's generated from `secrets-init.sh`'s inventory. CI checks that every secret has a revoke row.
- Steps, in order:
  1. delete the Cloudflare tunnel;
  2. revoke the Anthropic key;
  3. revoke the Discord webhooks (and later the bot token);
  4. revoke the GitHub tokens (fine-grained, read-only, with an expiry);
  5. rotate the Healthchecks ping URLs;
  6. revoke the B2 key;
  7. delete the Tailscale node (tagged nodes don't expire);
  8. remove the server's SSH host keys from `known_hosts`, and never accept the old fingerprint;
  9. rotate database passwords;
  10. change the home Wi-Fi password if it was ever stored on the server;
  11. treat the restic password as burned and re-create the off-site repo (changing a restic password doesn't rotate its master key);
  12. assume the backup drive is gone and readable.
- My user password is unique, because its hash is on the disk.

**Quarantine off the home network (Phase 2):** a root timer runs every minute and compares the default gateway's MAC with `GATEWAY_MAC` in `lan.conf`. After 5 misses in a row, it:
- stops cloudflared, the agent and Alertmanager;
- freezes deploys.

Watchdog then goes quiet, and Healthchecks emails me.

**Unexplained boots:** the handoff adds a line for any boot with no maintenance or power event behind it.

**`docs/runbooks/workstation-compromised.md`:**
1. At the server console, remove my keys from `allowed_signers` and `authorized_keys`.
2. Audit `main` since the last known-good `update.last`.
3. Rotate my GitHub, Cloudflare, Discord and Anthropic sessions.
4. Make new keys on a clean machine.

**`ConfigDrift` (Phase 2):** a daily hash of `/etc/ssh`, `~/.ssh/authorized_keys`, `/etc/sudoers*` and `/etc/systemd/system`, alerting on any change not made by `nightshift-update`.
