# Power design

Part of the Nightshift plan (`docs/PLAN.md`). This file owns what happens when wall power is lost: the emergency shutdown timer, the last-moment shutdown hook, the full power watcher, and the drills.

## Readings (shared by everything here)

- **AC:** the `power_supply` entry whose `type` is `Mains`; its `online` value must be `0` or `1`.
- **Battery:** `BAT0/capacity` must match `^[0-9]{1,3}$` and be between 0 and 100.
- **Anything else is UNKNOWN:**
  - write `nightshift_power_reading_unknown 1` (it has its own alert);
  - **never act on an UNKNOWN reading.**
- **Config** lives in `/etc/nightshift/power.conf` (root:root 0644). It's parsed as `KEY=VALUE` against a list of allowed keys, and **never `source`d**. The repo always has `DRY_RUN=true`, and CI checks this.
- **Laptop behavior:** "Power On with AC Attach" fires only at the moment AC appears. If the laptop powers off while AC is already present, nothing turns it back on. So every path here **reboots instead of powering off when AC is back.**

## Emergency shutdown timer (`nightshift-critical.timer`, Floor, Phase 2)

Protects the hardware from Phase 2 onward.

- **Timer:** `OnBootSec=60s`, `OnUnitActiveSec=30s`, `AccuracySec=1s`.
- **Each run:**
  1. Writes `nightshift_critical_timer_last_run_timestamp_seconds`, even in `DRY_RUN`. `CriticalTimerStale` alerts if it's missing or older than 5 minutes.
  2. Takes 3 readings, 5 seconds apart.
  3. Acts only if AC is 0 on all 3 **and** the battery is at or below `CRITICAL_PERCENT`: 30 until the watcher ships, then 15.
  4. Never acts during the first 5 minutes after boot while on AC.
- **Action:**
  1. Try the deploy lock for up to 60 seconds. If it's still busy, log that and proceed.
  2. Create `deploy.frozen`.
  3. Run `stop-all.sh` itself.
  4. Release the lock.
  5. **Check AC one last time:** if it's back, `systemctl reboot`; otherwise `systemctl poweroff`.

  Stopping the stacks *before* that last check shrinks the window in which AC can return while the laptop is still going down.
- **Phase 4:** once the watcher exists, the timer stands down while the watcher's heartbeat is less than 60 seconds old.
- **Rollout:** a week in `DRY_RUN`, then live after its drills (below).

## Last-moment shutdown hook (Floor, Phase 2)

systemd runs executables in `/usr/lib/systemd/system-shutdown/` at the very end of shutdown, with the action (`poweroff`, `reboot`, …) as the first argument. `/sys` is still available.

```sh
#!/bin/sh
# /usr/lib/systemd/system-shutdown/nightshift-ac-reboot  (root:root 0755)
[ "$1" = poweroff ] || exit 0
[ -e /run/nightshift/power/manual-poweroff ] && exit 0
for p in /sys/class/power_supply/*; do
  [ "$(cat "$p/type" 2>/dev/null)" = Mains ] && [ "$(cat "$p/online" 2>/dev/null)" = 1 ] \
    && exec /usr/bin/systemctl --force --force reboot
done
exit 0
```

- **Deliberate shutdowns:** run `sudo touch /run/nightshift/power/manual-poweroff` first, so the hook doesn't turn them into reboots. A `nightshift-poweroff` helper does both steps.
- **Drill it:** plug the charger back in during the ordered stop; the laptop must reboot, not stay off.
- **No RTC wake alarm:** this hook covers the case it was meant for.

## Power watcher (Target, Phase 4)

**Install and unit:**
- Installed by `nightshift-update` at `/usr/local/lib/nightshift/power-watcher.sh` (root:root 0755).
- The unit is `Before=nightshift-stacks.service`, so the watcher already runs during the up-to-20-minute boot. It has `Restart=always`.

**Readings:** every 10 seconds, using the shared readings above. A reading must repeat 3 times in a row before the watcher acts on it.

| Setting | Default | Meaning |
|---|---|---|
| `GRACE_MINUTES` | 10 | How long to ride out a blip |
| `SHUTDOWN_AT_PERCENT` | 40 | Start shutting down early at this battery level |
| `CRITICAL_PERCENT` | 15 | **Only while AC is 0:** power off now |
| `AC_STABLE_SECONDS` | 60 | How long AC must stay on before cancelling |
| `BOOT_GRACE_SECONDS` | 300 | Never start a shutdown in the first 5 minutes after boot while on AC |
| `SHUTDOWN_DEADLINE_SECONDS` | 300 | After this, `sync; systemctl poweroff` no matter what (after one last AC check) |

**States:**
- ON_AC → ON_BATTERY (grace; cancellable) → SHUTTING_DOWN → POWEROFF.
- SHUTTING_DOWN can be cancelled between steps, until the databases are stopped.
- Once the system itself is `stopping`, the state is final: no cancel and no recovery, only the last AC decision.

**State survives a crash.** The watcher writes `/run/nightshift/power/power.state` atomically (state, step, silence ID, frozen flag) and resumes from it after a restart.

**Freeze first:**
1. Take the deploy lock (at most 60 seconds) and create `deploy.frozen`.
2. Run `systemctl stop nightshift-backup.service`; restic releases its lock.
3. Cancel any chaos runs.
4. Create an Alertmanager silence for **`category="site-down"` only**, ending at grace + deadline + 15 minutes. Save its ID, and delete the silence on recovery. **Never silence `Watchdog`, `OnBattery` or `BackupMissing`.**

**Shutdown:**
- **Order:** edge and apps → platform → household (later) → databases → monitoring last.
- **Each step** runs in the background with `timeout --kill-after`, while the watcher keeps checking AC and battery.
- **Ending:** every path to POWEROFF (normal, deadline, critical) checks AC one last time and reboots if it's on.
- **No deadlock:** the watcher releases the lock just before calling `poweroff` or `reboot`. When the system is already stopping, `stop-all.sh` waits at most 10 seconds for the lock.
- **Hysteresis:** after 2 cancels within 30 minutes, AC must stay stable for 10 minutes before the next cancel. Once the databases are stopped, the watcher doesn't cancel; it finishes, then reboots if AC is back.

**Recovery after a cancel:**
- Restart the stopped stacks in startup order, run health checks, unfreeze deploys, and delete the silence.
- Household services wait for ≥ 50% battery or 5 minutes of stable AC.

**Other behavior:**
- **Charger vs. outage:** if the router still answers pings, the house probably has power. The watcher posts "Laptop charger unplugged?" and still follows the same rules.
- **Heartbeat:** written as a textfile metric. `PowerWatcherStale` (in the same PR as the watcher) alerts if it's missing or older than 120 seconds.
- **Events:** each one is appended to `/var/lib/nightshift/events/power-events.jsonl`. The events directory is mounted read-only into the agent. Discord posts are best-effort.

## Drills (start with `DRY_RUN=true`)

**Critical timer and hook (Phase 2):**
1. Unplug: the timer logs the right decision.
2. Boot on AC with the battery under the threshold: the laptop stays up.
3. Plug back in before the threshold: nothing happens.
4. Live, with a raised threshold: plug back in during the ordered stop; the hook reboots the laptop.

**Watcher (Phase 4):**
1. Unplug for 2 minutes; the watcher cancels.
2. Live, with a raised `SHUTDOWN_AT_PERCENT`: plug back in partway through; everything comes back healthy.
3. A full shutdown, then plug back in: the laptop boots, and the stacks come up in order.
4. Plug back in during the last step: the laptop reboots instead of staying off.
5. Boot on AC with the battery under 15%: the laptop stays up.
6. An unclean reboot (`echo b > /proc/sysrq-trigger`): the stacks recover, and Prometheus and Loki don't run out of memory replaying their logs.
7. `kill -9` the watcher mid-shutdown (`DRY_RUN`): it resumes from its state file.

**Measure the real battery runtime,** and confirm a full ordered stop takes less than 50% of the runtime from 40% down to 5%.
