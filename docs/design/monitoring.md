# Monitoring design

Part of the Nightshift plan (`docs/PLAN.md`). This file owns:
- metrics, logs and their limits;
- scrape trust;
- alert rules and their labels;
- the dead man's switches and Alertmanager.

## Components

| Component | Where | Notes |
|---|---|---|
| Prometheus | `obs`, `probe`, `cadvisor`, every `metrics_<app>` | Listens only on its `obs` IP. Admin and lifecycle APIs off. Basic auth. Data on the `mon-prometheus` volume |
| node_exporter | host (Debian package) | Textfile collector on `/var/lib/nightshift/metrics`. Scraped at the `probe` gateway IP; ufw allows only Prometheus's fixed `probe` IP |
| cAdvisor | `cadvisor` only | Root-equivalent (privileged). Pin a release that includes google/cadvisor#3709 (the containerd image store fix Docker 29 needs) |
| blackbox-inside | each `edge_<app>`, `chaos`, `probe` | Probes apps from inside Docker. Listens only on its `probe` IP |
| blackbox-outside | `probe`, `egress_blackbox` | Probes public URLs, and runs the `InternetDown` ICMP and HTTPS probes. Keeps `NET_RAW` for ICMP (listed in `exceptions.yml`) |
| Alertmanager | `obs`, `egress_alertmanager` | Basic auth, clustering off (`--cluster.listen-address=`), named volume, `127.0.0.1:9093` |
| Grafana | `obs`, `admin` | Dashboards as code, plugins provisioned, anonymous access and sign-up off, `127.0.0.1:3000` |
| Loki + Alloy (Target) | `obs` (+ `sockproxy_alloy`) | Opt-in logs only. Data on the `mon-loki` volume |

## Retention and caps

**Prometheus:**
- Keep 30 days, capped at 10 GB (with the flags or the config-file equivalent, whichever the pinned version supports), plus `--query.timeout=30s`.
- Its self-scrape job targets `<obs IP>:9090` with `basic_auth.password_file`. Its healthcheck reads the credential from the mounted secret at run time (`wget --header "Authorization: Basic $$(cat /run/secrets/prom_b64)" …/-/ready`), never a literal in the repo.

**Loki** (all under `limits_config` except the compactor):
- **Retention:** `compactor: {retention_enabled: true, delete_request_store: filesystem}` and `retention_period: 720h`.
- **Query caps:** `max_query_length: 24h`, `max_entries_limit_per_query: 1000`, `query_timeout: 30s`.
- **Ingestion caps:** `ingestion_rate_mb: 1`, `ingestion_burst_size_mb: 2`, `per_stream_rate_limit: 512KB`.

**Container logs:** the `local` log driver with `max-size: 10m` (`daemon.json`). This only applies to newly created containers.

**Resource limits:**
- every container gets `mem_limit`, `cpus` and `pids_limit`;
- Prometheus and Loki get at least 2× their steady-state memory, because replaying their logs after an unclean stop uses extra;
- `app-postgres` (and later Pi-hole) get `oom_score_adj: -500`.

**Disk:** a 10 GB ballast file at `/var/lib/nightshift/ballast`, to delete in an emergency.

## Scrape trust

Everything an app exposes is attacker-controlled. Every app scrape job gets:

```yaml
honor_labels: false
body_size_limit: 10MB
sample_limit: 5000
label_limit: 30
label_name_length_limit: 128
label_value_length_limit: 256
metric_relabel_configs:
  - source_labels: [__name__]
    regex: 'ALERTS.*|up|scrape_.*|node_.*|nightshift_.*|probe_.*|container_.*|prometheus_.*|alertmanager_.*'
    action: drop
  - action: labeldrop
    regex: 'stack|severity|scope|category|investigate|exported_.*'
```

- **Rules select by job**, for example `node_boot_time_seconds{job="node"}`. Rules over app metrics aggregate with `sum by (job, …)`.
- **The agent confirms alerts** through `GET /api/v1/alerts`, never the `ALERTS` series.

## Logs (Target)

- **Opt-in only.** Alloy keeps only containers labeled `nightshift.logs=true`, and never the household project.
- **Its own socket proxy:**

  ```
  -allowfrom=alloy -allowHEAD=/_ping -allowGET='/v1\.[0-9]{2}/(version|events|containers/json|containers/[0-9a-f]{12,64}/(json|logs))'
  ```

  Confirm the endpoints with `-loglevel=DEBUG`. Never use label mode.
- **Redaction:** `loki.secretfilter` runs before `loki.write`. Apps redact `authorization`, `cookie`, `*password*` and `*token*`, and never log connection strings.

## Metrics written by my code

Each writer owns one file in `/var/lib/nightshift/metrics/`, written with `write_metric()` (`host-ops.md`).

| File | Metrics | Writer |
|---|---|---|
| `stacks.prom` | `nightshift_stack_up{stack}`, `nightshift_boot_complete_timestamp_seconds`, `nightshift_compose_drift{stack}` | `start-all.sh`, reconcile |
| `deploy.prom` | `nightshift_deploy_last_poll_timestamp_seconds{app}`, `nightshift_deploy_last_result{app}`, `nightshift_deploy_frozen`, `nightshift_deploy_lock_held_seconds` | deploy service (copied in by a root timer) |
| `backup.prom` | `nightshift_backup_last_success_timestamp_seconds`, `nightshift_backup_bytes` | backup |
| `restore.prom` | `nightshift_restore_test_last_success_timestamp_seconds` | restore test |
| `host-daily.prom` | `nightshift_apt_security_pending`, `nightshift_dpkg_audit_problems`, `nightshift_unattended_upgrades_last_success_timestamp_seconds`, `nightshift_reboot_required`, `nightshift_shim_hold_pending`, `nightshift_boot_free_bytes`, `nightshift_secret_perms_bad` | daily host check |
| `lanblock.prom` | `nightshift_lanblock_loaded` | 5-minute timer |
| `critical.prom` | `nightshift_critical_timer_last_run_timestamp_seconds`, `nightshift_power_reading_unknown` | critical timer |
| `quarantine.prom` | `nightshift_gateway_match` | quarantine timer |
| `power.prom` | `nightshift_power_watcher_heartbeat_timestamp_seconds`, `nightshift_power_state` | power watcher (Phase 4) |

**Staleness:** gauges survive reboots, so staleness is checked per file. For example:

```
(time() - node_textfile_mtime_seconds{job="node",file=~".*stacks.prom"} > 1800)
  or absent(node_textfile_mtime_seconds{job="node",file=~".*stacks.prom"})
```

plus `node_textfile_scrape_error == 1`.

## Labels on every rule

Every rule sets all five labels explicitly, and a CI lint checks it:

| Label | Values |
|---|---|
| `stack` | the stack the alert is about |
| `severity` | |
| `scope` | `public` or `internal` |
| `category` | `site-down` for alerts that maintenance and power silences may mute |
| `investigate` | `"true"` only for site down, high 5xx, restart loop, memory pressure and disk filling; `"false"` everywhere else |

## Boot settling

```yaml
- record: nightshift:boot_settled
  expr: (nightshift_boot_complete_timestamp_seconds{job="node"} > on() node_boot_time_seconds{job="node"})
        and on() (time() - nightshift_boot_complete_timestamp_seconds{job="node"} > 600)
```

- **Boot-sensitive rules** (site down, deploy polling stale, stack down) append `and on() nightshift:boot_settled`.
- **Staleness and `absent()` rules** use `for: 10m`.
- **The agent** doesn't investigate while `nightshift:boot_settled` is absent or `InternetDown` is firing. Inhibit rules would mute alerts for every receiver, so this suppression lives in the agent.

## Alert rules

Each rule is tested with `promtool test rules`, including the "metric missing" case, and added in the same PR as the thing that produces its metric.

**Sites:**
- Site down from inside Docker (`for: 1m`).
- Site down from outside (`for: 5m`).
- High 5xx rate (`for: 1m`).
- `DeployFailed` (`nightshift_deploy_last_result == 0`).
- `DeployLockHeldTooLong` (more than 15 minutes).

**Host and containers:**
- **Disk:** above 80% or 90% on every real mountpoint, `/boot` included (`node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}`), or `predict_linear(...[6h], 24*3600) < 0`.
- **Memory pressure.**
- **Restart loop:** a container restarting repeatedly.
- **OOM kill:** in a monitoring container.
- **Hardware:** CPU temperature, battery health and SMART warnings.
- **`OnBattery`:** `node_power_supply_online{job="node",power_supply="AC"} == 0`, `for: 1m`.
- **`CadvisorBlind`:** `(count(container_last_seen{job="cadvisor",name!=""}) or vector(0)) < 5`, `for: 10m`.
- **`MonitoringVolumeMissing`:** a monitoring mountpoint absent from `node_filesystem_avail_bytes`.

**Safety controls:**
- `LanBlockMissing`: `nightshift_lanblock_loaded == 0 or absent(...)`.
- `CriticalTimerStale`: more than 300 seconds, or absent.
- `PowerReadingUnknown`.
- `PowerWatcherStale` (Phase 4).
- `SecretPermsBad`.
- `NotOnHomeNetwork`: `nightshift_gateway_match == 0`.

**Staleness** (each `(time() - X > N) or absent(X)`):
- `BackupMissing`, after 26 hours;
- `RestoreTestStale`, after 40 days;
- deploy polling stale;
- unattended-upgrades stale, after 48 hours.

**Pending work:**
- `StackDown`.
- `RebootPending`, after more than 7 days (after Dec 13).
- Security updates pending for more than 3 days.
- Any dpkg problem.

**Monitoring itself:**
- Time sync lost.
- `NotificationsFailing`: `alertmanager_notifications_failed_total` increasing.
- `InhibitorStuck`: `InternetDown` firing for more than 2 hours.
- `ICMPProbeBroken`: ICMP failing while HTTPS succeeds, `for: 30m`.

## Internet outages

- `InternetDown` fires only when both the ICMP (`1.1.1.1`, `9.9.9.9`) and HTTPS internet probes fail for 2 minutes.
- It's also routed to Discord, so if you see it there, it was a false positive.
- A site that's healthy inside Docker but failing through the tunnel is an edge or ISP problem, and the agent doesn't investigate it.

## Dead man's switches (Healthchecks.io, by email)

| Check | Pinged by | Notes |
|---|---|---|
| Watchdog | the always-firing `Watchdog` alert (`expr: vector(1)`), on its own route (`group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 1m`) | Grace = the measured worst-case reboot-to-first-ping time + 5 minutes. Never paused around reboots |
| Backups | the backup unit | Cron check, time zone `America/Los_Angeles` (`backups.md`) |
| Handoff | the morning handoff, only after Discord returns 2xx | Doubles as a daily delivery test (Phase 3) |
| Notifications | Alertmanager pings `/fail` for `NotificationsFailing` and `InhibitorStuck`; a host timer pings success only when neither is active (command below) | Its own check, because Healthchecks only emails when a check changes state |

The notifications timer pings success only when this returns nothing:

```
amtool alert query 'alertname=~"NotificationsFailing|InhibitorStuck"'
```

**Drills:** break the Discord webhook, and stop Alertmanager; each one must produce an email.

## Alertmanager

- **Grouping:** by `[alertname, stack]`, with `group_wait: 10s` for investigate routes.
- **Secrets from files:** `webhook_url_file`, `credentials_file` and `url_file`, checked against the pinned version.
- **Discord templates** show only enum fields.
