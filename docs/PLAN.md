# Nightshift — Project Plan

> A self-hosted home lab on a spare ThinkPad, with an AI on-call engineer.
> TCSS 490, Artifact 5 (The Moonshot).

**Status:** Planned, and reviewed three times on 2026-11-14 (summary in `docs/reviews/README.md`). Design details live in `docs/design/` (section 8). Next step: the scaffold.
**Last updated:** 2026-11-14

---

## 1. Goal

Turn a spare ThinkPad into a server that:

1. **Hosts my own projects on the public web.** Each one gets its own URL through Cloudflare Tunnel, with no open router ports.
2. **Deploys automatically** when I push to GitHub, by image digest, with strict checks on what a deploy may do.
3. **Monitors everything around the clock**, including the monitoring itself.
4. **Has an AI on-call engineer.** When an alert fires, an agent investigates with read-only tools and posts a diagnosis and a proposed fix to Discord. *One-tap approval is Moonshot tier.*
5. **Writes a morning handoff** about the night before and what needs me.
6. **Survives power outages and reboots cleanly**, and comes back on its own.
7. **Later, outside this project:** home-network services on their own encrypted volume (planned privately), and read-only monitoring of apps hosted elsewhere, with the owner's approval.

**Show-and-tell (Mon Dec 7):** a presentation of what I built and learned, using screenshots, the Discord history and eval results. No live demo.

**Scope on purpose:** this project is meant to be bigger than the course hours. Section 9 is a **priority order**: the most important work comes first, and anything unfinished by Dec 13 continues afterward.

---

## 2. Course context

- **Assignment:** TCSS 490 Artifact 5, "The Moonshot." It takes 40–60 hours over five weeks and is graded on a genuine attempt.
- **Weekly portfolio submissions** (end of Weeks 6–9): my portfolio link, with the Artifact 5 card updated, on **Sun Nov 15, Nov 22, Nov 29 and Dec 6**.
- **Monday office hours:** show progress on **Nov 16, 23 and 30**. Each needs about 15 minutes of prep (a screenshot and a status line) plus a log entry.
- **Final show-and-tell:** Mon Dec 7.
- **Due:** Sun Dec 13, 11:59 PM. The final card needs a title, a link and a short reflection.
- **What "complete" means:** a genuine attempt, a repo with **a log of plans and changes** (`LOG.md`), and the card on my portfolio.

| Outcome | Evidence |
|---|---|
| AO1: Plan and scaffold something too big to hold in one head | This plan, `docs/design/`, `CLAUDE.md`, the skeleton, definitions of done |
| AO2: Keep a long project on track | `LOG.md`, weekly submissions, Monday check-ins |
| AO3: Ship something people can use | My projects live at public URLs |
| LO 3: Break problems into AI-sized tasks | Phase tasks sized to one session, each with a definition of done |
| LO 7: Plan and version with traceability | The log, `docs/decisions/`, the review summary, signed merges, deploy and audit records |
| LO 8: Extend large, unfamiliar codebases | Configuring Prometheus, Alertmanager, Loki/Alloy and cloudflared; containerizing existing apps |
| LO 9: Communicate technical decisions | Decision records (including dropping disk encryption), runbooks, the show-and-tell, the reflection |
| LO 12: AI as an active component | The on-call agent |
| LO 13: Trade-offs (cost, latency, reliability, security) | Eval results; template vs. AI in the handoff; agent safety design; the disk-encryption decision |

---

## 3. Hardware and OS

| Machine | Role |
|---|---|
| **ThinkPad T480s** (quad-core i5, 24 GB RAM, 1 TB SSD, built-in RJ-45) | **Server.** Debian 13, headless, unencrypted LVM (300 GB root + free space). Reinstalled with `docs/runbooks/reinstall-server.md`. Runs around the clock; no desktop use. |
| **Windows laptop** | **Workstation.** Code, Claude Code, Git, SSH, and the dashboards through an SSH tunnel. |

**Key decisions** (details in `design/host-ops.md`):
- **No full-disk encryption for now.** Every secret on the server is revocable. Household data later gets its own encrypted volume and backups.
- **Secure Boot stays on.** Check for the "Microsoft UEFI CA 2023" certificate before the first upgrade, and hold the shim packages if it's missing.
- **Signed changes only.** The server installs repo changes only if every first-parent commit is signed by my dedicated signing key, and only after I review the diff and confirm.

**To buy or set up:**
- a 2 TB external hard drive for backups;
- a domain on Cloudflare;
- an off-site backup bucket, before any household data.

---

## 4. Architecture

```
GitHub push ─► GitHub Actions builds the image (:sha-<git>, moves :main) ─► GHCR (public)
                                                   │  the laptop PULLS; nothing pushes in
                                                   ▼
   deploy service ─ polls :main via the Docker API ─► checks image + compose file ─► up by DIGEST ─► health check
   (the ONLY service that writes to Docker; no internet)      saves the validated file as "what runs"
                                                   │
             my apps ◄─────────────────────────────┘   (internal networks only: no internet, no LAN, no each other)
               │ metrics, logs
         Prometheus + Loki ─► Alertmanager ─► Discord (raw alerts)
                 │                 │
                 │                 ├─► Watchdog every minute ─► Healthchecks.io (emails me if it stops)
                 │                 ▼ webhook (shared secret)
                 │          AI on-call agent ── read-only tools ──► metrics, logs, container list, deploys, diffs
                 │                 │
                 │                 ▼ (posts with a Discord webhook; it can't approve or change anything)
                 │     Discord: "Likely cause: … Proposed fix: roll back <app>?"
                 │
                 └── (Moonshot) executor owns the Discord bot ─► Approve ─► deploy API
```

| Piece | Summary | Details |
|---|---|---|
| Public traffic | Visitor → Cloudflare → a **locally managed** tunnel whose hostnames live in the repo → app. The ingress ends with a 404 catch-all | `design/network.md` |
| Networks | Defined once in `host/setup/networks.tsv`: per-app internal networks, one egress network per service that needs it, only Prometheus bridges zones. An nftables LAN block stops containers from reaching the home network, and Docker won't start without it | `design/network.md` |
| Deploys | Pull by digest. A raw-YAML check, a sandboxed resolve, a strict schema, and an image-config check. Failed deploys restore the last good version and hold the revision | `design/deploy.md` |
| Host | Ordered start and stop, a guarded reconcile, signed updates with a review gate, a gated weekly maintenance reboot | `design/host-ops.md` |
| Power | An emergency shutdown timer and a last-moment "reboot if AC is back" hook (Phase 2); the full power watcher (Phase 4) | `design/power.md` |
| Backups | Verified dumps, restic to an external drive, a monthly restore test, an off-site copy before photos | `design/backups.md` |
| Monitoring | Prometheus, node_exporter on the host, cAdvisor, blackbox, Alertmanager, Grafana; Loki and Alloy as Target. Scrape trust rules, staleness rules, and four dead man's switches | `design/monitoring.md` |
| AI on-call | Read-only tools, budgets, redaction, prompts built in code, audit tables; a chaos stack for evals; executor (Moonshot) | `design/oncall.md` |
| Handoff | Daily facts from queries, a two-sentence AI summary | `design/handoff.md` |

---

## 5. Tech stack (pinned)

| Layer | Choice | Notes |
|---|---|---|
| Server OS | **Debian 13**, systemd, LVM, headless | ufw, TLP, unattended-upgrades, OpenSSH, nftables |
| Containers | **Docker Engine**, with docker-ce, containerd and the Compose plugin each pinned to their major version | `daemon.json`: `local` log driver (`max-size 10m`), `live-restore`, `dns`, `bip 10.200.0.1/24`, pool `10.201.0.0/16`. Moonshot option: k3s + Flux or Argo CD |
| Ingress | Cloudflare Tunnel (locally managed) + Cloudflare DNS | Optional: Tailscale for admin access |
| My services | **TypeScript on Node.js 24** (Maintenance LTS; pinned in `.nvmrc`, `engines` and `FROM`) | **Express 5**, **zod 4**, **Prisma 7** (ESM, driver adapter, `prisma.config.ts`; no automatic `.env` loading), **Vitest**, `express-rate-limit` |
| API docs | Hand-written OpenAPI spec rendered with Scalar | The on-call webhook; later the deploy API |
| AI | Claude API via `@anthropic-ai/sdk` (tool use) | Its **own Anthropic workspace with a monthly spend limit**. Model chosen by evals |
| Chat | Discord | Webhooks for the agent and the handoff. Only the executor (Moonshot) holds a bot token |
| Databases | PostgreSQL: `app-postgres`, `nightshift-db`, `chaos-db` | Exact image versions. For 18+, mount the volume at `/var/lib/postgresql` |
| Metrics | Prometheus, node_exporter (host package), cAdvisor (pinned to a release with the Docker 29 fix), blackbox_exporter | |
| Logs | Loki + Grafana Alloy | Promtail reached end of life on Mar 2, 2026 |
| Alerts | Alertmanager → Discord; Healthchecks.io dead man's switches | |
| Dashboards | Grafana, dashboards as code | |
| Container API access | **wollomatic/socket-proxy**, one instance per consumer | Not Tecnativa (CVE-2026-78122) |
| CI/CD | GitHub Actions (GitHub-hosted runners) → **public** GHCR → pull-based deploy service | SHA-pinned actions, Renovate, Trivy, gitleaks, shellcheck |
| Backups | restic + `pg_dump` → external drive, plus off-site before photos | |
| Host scripts | **Bash + systemd units** | Installed by `nightshift-update`; never run from the checkout |

---

## 6. Services and tiers

> **Floor** = must ship. **Target** = the real goal. **Moonshot** = stretch. **Optional** = only if useful.

| Tier | Services |
|---|---|
| **Floor** | OpenSSH, ufw, unattended-upgrades, TLP, Docker; node_exporter; `nightshift-lanblock`, `nightshift-stacks` + reconcile, `nightshift-backup`, `nightshift-maintenance`, `nightshift-critical` + the shutdown hook *(I write these)*; cloudflared; my apps, `app-postgres`, `nightshift-db`; **deploy service** + CLI *(I write this)*; Prometheus, cAdvisor, blackbox-inside/outside, Alertmanager, Grafana, Healthchecks.io |
| **Target** | **On-call agent** + **morning handoff** *(I write this)*; its socket proxy; chaos stack; Loki + Alloy (+ Alloy's socket proxy); **power watcher** *(I write this)*; automated migrations; build provenance |
| **Moonshot** | **Executor** + deploy API *(I write this)*; postmortems as PRs I open; k3s + GitOps |
| **Optional** | Tailscale |
| **After Dec 13** (not graded) | Home-network services: Pi-hole, Samba, Immich (planned privately); external targets (`design/external-targets.md`) |

---

## 7. Repository structure

```
nightshift/
├── CLAUDE.md                 # short: context, stack, structure, rules; points at docs/
├── README.md                 # what it is, the diagram, screenshots, how to rebuild
├── LOG.md                    # course-required log: one dated entry per piece of work
├── .gitattributes            # * text=auto eol=lf
├── .gitignore                # .env, *.env, secrets/, data/, backups/, private/, *.local.*
├── private/                  # my private notes: git-ignored, never committed
├── .env.example              # variable NAMES only
├── .claude/settings.json     # attribution off; deny rules; ask rules (section 10)
├── .githooks/               # commit-msg, pre-commit, pre-push (git config core.hooksPath .githooks)
├── docs/
│   ├── PLAN.md               # this file
│   ├── design/               # network, deploy, host-ops, power, backups, monitoring, oncall, handoff, external-targets
│   ├── reviews/README.md     # summary of the three plan reviews (full reports kept privately)
│   ├── decisions/            # 0001-deploy-model.md, 0002-disk-encryption.md, ...
│   ├── runbooks/             # reinstall-server, laptop-stolen, workstation-compromised, migrate, new-app, docker-major-upgrade, ...
│   └── incidents/            # postmortems (Moonshot)
├── host/
│   ├── setup/                # networks.tsv, lanblock, logind, TLP, SSH, ufw, Docker, sysctl, tmpfiles, swap, secrets-init.sh, nightshift-update
│   ├── startup/              # nightshift-stacks, start-all.sh, stop-all.sh, reconcile, chaos-reset, nightshift-apply
│   ├── power/                # critical timer, shutdown hook, power watcher, power.conf.example
│   ├── backup/               # backup unit, timers, run.sh, restore-test.sh
│   ├── maintenance/          # weekly window, daily host checks, quarantine timer
│   └── lib/                  # lock.sh, write_metric, validated config parsing
├── policy/                   # compose policy (raw check + zod schemas), exceptions.yml; shared by CI and the deploy image
├── stacks/                   # one Compose project per folder; networks are external (from networks.tsv)
│   ├── edge/                 # cloudflared + config.yml (ingress), no credentials in the repo
│   ├── postgres/             # app-postgres
│   ├── platform/             # nightshift-db, deploy, oncall, socket proxies, (executor); project nightshift-platform
│   ├── monitoring/           # Prometheus, rules, Alertmanager, Grafana, Loki, Alloy, blackbox, cAdvisor
│   ├── apps/<app>/compose.yml # config only; image: ${IMAGE:?}; the running digest lives on the server
│   ├── chaos/                # chaos-target + chaos-db
│   ├── pihole/, nas/         # household (after Dec 13)
├── apps/chaos-target/        # source for the chaos app
├── deploy/                   # deploy service + CLI (TypeScript)
├── oncall/                   # on-call agent + handoff (TypeScript)
├── executor/                 # executor (TypeScript, Moonshot)
├── chaos/                    # break-it scripts, each with an automatic revert
├── evals/                    # scenarios (synthetic logs), expected causes, results
├── targets/example.yml       # real target configs live in /etc/nightshift/targets/
└── .github/workflows/        # CI: typecheck, tests, lint, gitleaks, policy, network rules, attribution check
```

Hosted apps stay in **their own repos**, and each builds and publishes its own image. This repo never holds a tag or digest for them.

---

## 8. Design documents

Each fact lives in one place. When this plan and a design doc disagree, fix whichever is wrong in the same commit.

| Doc | Owns |
|---|---|
| `design/network.md` | `networks.tsv`, network classes and rules, the LAN block, the tunnel, admin and remote access |
| `design/deploy.md` | Build, what runs, the deploy steps, the compose policy, rollback and holds, the CLI, migrations, supply chain |
| `design/host-ops.md` | Disk encryption, disk layout, Secure Boot, BIOS, laptop settings, emergency console, signed updates, shared plumbing, boot ordering, maintenance, daily checks, theft response |
| `design/power.md` | Critical timer, shutdown hook, power watcher, drills |
| `design/backups.md` | Dumps, restic, schedule, restore test, keys, off-site |
| `design/monitoring.md` | Components, caps, scrape trust, metric files, labels, rules, dead man's switches, Alertmanager |
| `design/oncall.md` | Agent flow, tools, budgets, safety rules, DB roles, executor, chaos stack |
| `design/handoff.md` | The morning handoff |
| `design/external-targets.md` | Read-only monitoring of apps hosted elsewhere (deferred) |
| `runbooks/reinstall-server.md` | Wiping and reinstalling the server |

---

## 9. Schedule and priorities

> **Floor work comes first in every phase.** Anything unfinished by Dec 13 continues afterward.
> **If behind, these move past Dec 13 first:** k3s → postmortems → executor → chaos 2/4/5 → `deploy_diff` → Loki/Alloy (with `search_logs`) → power watcher (the critical timer and hook stay) → AI handoff summary → custom dashboards.
> **Never move:** budgets, audit tables, secret handling, the network rules and LAN block, the compose policy, backups with a restore test, the critical timer and shutdown hook, the weekly submissions.
> **Before any trip:** set `AUTO_REBOOT=false` in `/etc/nightshift/maintenance.conf`. Travel dates stay out of this public repo.

### Phase 0: Scaffold (Nov 14–15)
- [ ] Create the public repo `nightshift`, with `.gitattributes`, `.gitignore` and `.env.example` before the first real commit
- [ ] `.claude/settings.json`, `.githooks/commit-msg`, then `git config core.hooksPath .githooks`
- [ ] `CLAUDE.md`, the skeleton, `docs/` (plan, design, runbooks, review summary), the first `LOG.md` entry
- [ ] Draft `docs/decisions/0002-disk-encryption.md` from `design/host-ops.md`
- [ ] Turn on GitHub secret scanning and push protection
- [ ] **Submit the portfolio link with the updated Artifact 5 card (Sun Nov 15, 11:59 PM)**
- [ ] *(After the submission is fine)* **Signing:**
  - Create the `nightshift_signing` key with a passphrase, and never `ssh-add` it.
  - Run `git config gpg.format ssh`, `user.signingkey …`, `commit.gpgsign false` and `gpg.ssh.allowedSignersFile …`.
  - Test a signed `develop` → `main` release (`design/host-ops.md`).
  - Add the GitHub ruleset on `main`.
- [ ] **Accounts and lead times:**
  - Domain on Cloudflare, plus a Zero Trust org
  - Private Discord server, alert and handoff webhooks
  - Anthropic workspace with a spend limit
  - Healthchecks.io
  - Order the backup drive
  - Passkeys or 2FA, and registrar lock
- **Done when:**
  - a test secret push is blocked;
  - `.sh` files check out with LF endings;
  - the commit hook rejects an attribution line;
  - the card is submitted.

### Phase 1: Floor, server baseline and the first deployed app (Nov 16–22)
- [ ] Mon Nov 16: office-hours check-in (log entry)
- [ ] **Reinstall** with `docs/runbooks/reinstall-server.md`. This covers:
  - the Secure Boot check and shim hold before the first upgrade
  - the emergency console drop-ins and their test
  - SSH keys and the host-key check
  - the BIOS locks at the end
- [ ] **`host/setup/` basics:**
  - SSH drop-ins
  - ufw
  - unattended-upgrades
  - logind/sleep
  - TLP
  - static IP and the `auto` stanza
  - resolvers
  - `kernel.panic`
  - the watchdog
  - encrypted swap and no core dumps
- [ ] **`host/setup/` Docker, plumbing and secrets:**
  - Docker with pinned majors and `daemon.json`
  - tmpfiles and `host/lib/`
  - `secrets-init.sh`
  - a root-owned `/opt/nightshift` with `nightshift-update` (signature check, review gate, `update.last` seeded by hand)
- [ ] **Write `laptop-stolen.md` and `workstation-compromised.md`** before the first token goes on the server, and practice one revocation
- [ ] **Networks:**
  - `networks.tsv` and network creation in `start-all.sh`
  - `nightshift-lanblock` (fail closed), its loaded metric, and the acceptance test from every non-internal network
- [ ] **Databases:** `app-postgres` and `nightshift-db`, with secrets as files and `pg_hba` per app and per role. App roles: `<app>` for data only, `<app>_migrate` owns the schema
- [ ] **cloudflared:** a locally managed tunnel, with `config.yml` in the repo, `--metrics 127.0.0.1:20241`, and `ingress validate` in CI
- [ ] **First app:** one of my solo projects that needs no schema changes during the course. CI publishes on `main` only, with `--ignore-scripts` and the container baseline
- [ ] **`policy/`:** the raw-YAML check, the sandboxed resolve, the strict schemas, the image-config check, `exceptions.yml`, and the negative tests (`design/deploy.md`)
- [ ] **Deploy service v1:** state files, failure handling (restore and auto-hold), holds by revision, the CLI verbs, the migration gate, polling via the Docker API, the lock
- [ ] **`nightshift-stacks`:** `start-all.sh` (15-minute deadline, mount checks, re-validating apps), `stop-all.sh`, the guarded reconcile, `nightshift-apply`, `nightshift-chaos-reset`
- [ ] **Backups:** unit, timers, snapshot-consistent dumps, restic, a cron check with its time zone, **a restore test from the restic repo**
- [ ] **Resource limits and healthchecks** on every Phase 1 service
- [ ] **Submit Sun Nov 22**
- **Done when:**
  - SSH with a password is refused, and `nmap` from the LAN shows only port 22.
  - The emergency target gives a root shell at the console.
  - The LAN-block test passes, including after `systemctl restart docker`. Docker refuses to start without the table.
  - A push is live, by digest, within 5 minutes. A deliberately failing build is restored and held automatically.
  - Every negative policy test is rejected, and every Phase 1 stack passes.
  - After `systemctl reboot`:
    - everything is healthy, on the same digests;
    - holds survive;
    - Postgres logs a clean shutdown.
  - A restic restore matches the recorded row counts.

### Phase 2: Floor, monitoring and alerting (Nov 23–29)
- [ ] Mon Nov 23: office-hours check-in (log entry)
- [ ] Create the `mon-prometheus` and `mon-loki` volumes
- [ ] Prometheus (scrape trust, self-scrape with auth), node_exporter on the host, cAdvisor (pinned), blackbox-inside and blackbox-outside
- [ ] Alertmanager (`127.0.0.1`, clustering off) → Discord; the four Healthchecks.io checks; the metric files and labels; the rules, with `promtool` tests (including "metric missing"); boot settling
- [ ] Grafana, with dashboards as code, reached through `ssh -L`
- [ ] Daily host checks; the weekly maintenance window, its reboot checks, and recreating the proxies after Docker updates
- [ ] `nightshift-critical.timer` and the shutdown hook: a week in `DRY_RUN`, then live after their 4 drills (`design/power.md`)
- [ ] The quarantine timer and `ConfigDrift`
- [ ] Loki and Alloy, with opt-in logs and their socket proxy *(Target, if ahead)*
- [ ] Start the on-call agent on Windows, against saved sample Alertmanager payloads
- [ ] **Submit Sun Nov 29**
- **Done when:**
  - every rule has fired in a test;
  - each dead man's switch emails me in its drill;
  - the maintenance window defers its reboot when a check fails;
  - the critical timer and the hook pass their drills;
  - `CadvisorBlind` stays quiet.

### Phase 3: Target, the AI on-call (Nov 30–Dec 6)
- [ ] Mon Nov 30: office-hours check-in (log entry)
- [ ] Webhook receiver: API confirmation, deduplication, boot and InternetDown skips, incidents that close only on "resolved"
- [ ] The chaos stack (its own schema, probing, reset service) and scenarios 1 and 3 (then 2, 4 and 5 if time allows)
- [ ] Tools: `query_metrics`, `container_status`, `recent_deploys`, then `search_logs` (if Loki) and `deploy_diff`
- [ ] The investigation loop: budgets, redaction, prompts built in code, zod-validated output, Discord webhook posts
- [ ] Audit tables with the `oncall` and `retention` roles, plus a test that runs every write as `oncall`
- [ ] Morning handoff (template version)
- [ ] `evals/`: each scenario × several runs
- [ ] **Sat Dec 5: freeze.** Sun Dec 6 (~1.5 h): the show-and-tell deck and README screenshots
- [ ] **Submit Sun Dec 6**
- **Done when:** chaos scenarios 1 and 3 each produce a correct diagnosis with a sensible proposed action in Discord, 3 times out of 3, within 4 minutes of the break.

### Mon Dec 7: Show-and-tell

### Phase 4: Finish and next tier (Dec 7–13)
- [ ] Power watcher (Target), with its 7 drills (`design/power.md`)
- [ ] Claude-written handoff summary
- [ ] More evals and a written trade-off summary (LO 13)
- [ ] D-10: decide on Secure Boot if the 2023 certificate never arrived
- [ ] **Final log entry; final card (title, link, 3–5 sentence reflection) and Canvas by Sun Dec 13, 11:59 PM**
- [ ] As time allows:
  - anything open from earlier phases
  - build provenance
  - automated migrations
  - Moonshot

### After Dec 13 (the project continues)
1. Anything Floor or Target still open.
2. **Extras:**
   - the `RebootPending` alert
   - the TLS-expiry line in the handoff
   - the backup-size alert
3. **Home-network services (planned privately):** off-site backup and restore test first, then the encrypted volume, then the services.
4. **External targets,** with the app owner's written approval (`design/external-targets.md`).
5. **Moonshot:** executor and deploy API, postmortems, k3s.

---

## 10. Rules for Claude Code (to move into `CLAUDE.md`)

**Working rules**
- **Secrets:** never read, print or commit `.env` files or secrets. Use the variable names from `.env.example`.
- **Commits:**
  - **Branches:**
    - `main` is the source of truth; the server deploys only from it.
    - `develop` is where tested work rests before release.
    - Feature branches (`feature/<topic>`) come off `develop`.
  - **Claude Code** may commit on feature branches and `develop`, and merge feature branches into `develop`. **Pushes are mine:** Claude Code never pushes. Commits are mine: no AI attribution.
  - **Never commit to, merge into, rebase or push `main`.** Releases are mine: after testing on `develop`, I run `git switch main && git merge --no-ff -S develop && git push origin main`, then `git switch develop && git merge --ff-only main`.
- **This repo is public.** Follow "Public repo hygiene" below in code, docs, logs, commit messages and screenshots.
- **`docs/PLAN.md` and `docs/design/` are the source of truth.** `docs/reviews/README.md` is only a summary.
- **One home per fact.** When you change a design detail, update its design doc (section 8) in the same commit.
- **Change flow:**
  - Every change goes through the repo. The only server-side state is listed in `design/host-ops.md`.
  - Host scripts are installed by `nightshift-update`, never run from the checkout.
- **Networks:**
  - Follow the network rules in `design/network.md`.
  - Networks come only from `networks.tsv`, and compose files declare them `external: true`.
  - Ask before adding a network.
- **Containers and Compose:**
  - **Secrets** are always files: Compose `secrets:` plus `*_FILE` or `*_file` settings. Never secrets in `environment:`.
  - **Admin ports** are published on `127.0.0.1` only (household: the LAN IPv4 only).
  - **Infra images** are pinned by digest or exact tag. App compose files never contain a tag or digest.
  - **Bind-mount directories, not single files** (long syntax, `create_host_path: false`).
- **Bash:** validate every value before using it in arithmetic or a command.
- **Hands off the server:**
  - **Never touch `stacks/pihole/` or `stacks/nas/`** in chaos or eval work. Chaos scripts only target the `nightshift-chaos` project.
  - **Never, without me:** run the power watcher or the critical timer live, trigger a shutdown or reboot, update firmware, or run chaos on the server.
  - **Nightshift's runtime never writes to external targets.**
- **Code:**
  - Migrations are expand/contract only.
  - TypeScript in strict mode, with Vitest tests.
- **Ask before** adding a container, a network, or a `dependencies` entry.
- **Log:** add a numbered, dated entry to `LOG.md` for each piece of work: what was asked, what changed, and what's next.

**Public repo hygiene** (the repo and its history are public)
- **Fine to publish:** my name, school, GitHub username and commit email; the architecture and design; placeholder examples.
- **Never commit**, in code, docs, `LOG.md`, commit messages, issues or screenshots:
  - **Schedules:** travel or away dates, and when the house is empty.
  - **Home network:** real LAN addresses and ranges, router details, MAC addresses, Wi-Fi names.
  - **Machine identifiers:** SSH host fingerprints, serial numbers.
  - **Accounts:** Discord server, channel or user IDs; webhook, Healthchecks, tunnel or other credential URLs and files.
  - **Other people:** names, details and data of companies, clients, teammates or other projects; anything about the people in my home or their data.
  - **Real data:** real log lines, IPs or emails other than mine. Evals and tests use synthetic data only.
- **Where those details live instead:** in `/etc/nightshift/` on the server, or in `private/` at the repo root.
  - It's git-ignored (`.gitignore` and `.git/info/exclude`), the pre-commit and pre-push hooks reject any path under it, and CI fails if it ever appears.
  - Read it only when I ask, and never copy anything from it into tracked files.
- **Screenshots** for the README and the deck are cropped or blurred: no IPs, IDs, tokens, URLs with secrets, or real user data.
- **Before pushing,** check the diff for any of the above. A pushed secret stays in git history, so rotate it, don't just delete it.

**Enforced mechanically**
- **`.claude/settings.json`** (every shell rule is written for both Bash and PowerShell):
  - `"attribution": {"commit": "", "pr": "", "sessionUrl": false}`
  - `"permissions": {"disableBypassPermissionsMode": "disable", …}`
  - **deny:** `Read` on `**/.env`, `**/*.env`, `**/secrets/**`; every `git push` (pushes are mine), and on top of that force pushes and pushes to `main`; `git commit --no-verify`, `git commit -n` and changing `core.hooksPath`; switching to, moving or deleting `main`; `git add -f`/`--force`; `git clean`; `gh auth`
  - **ask:** `ssh`, `scp`, `sftp`, `rsync`; `gh`; `npm install`/`i`/`add`, `npx`, `npm exec`, `npm create`, `npm init`; `git reset --hard`, `git branch -D`, `git stash drop`/`clear` and restoring the whole tree; reading or editing `private/`; editing `.claude/`, `.githooks/`, `.github/workflows/`, `.gitignore` and `.gitattributes`
  - **Behind these:** no real secrets live on the workstation, the signing key isn't in ssh-agent, `npm config set ignore-scripts true` is set, and the server's signature check and review gate stand behind it all.
- **`.githooks/`:**
  - **`commit-msg`:** `grep -qiE '^(co-authored-by:.*(claude|anthropic)|claude-session:|.*generated with \[?claude code)|claude\.ai/code/session'` rejects the commit. `pre-push` runs it on every outgoing commit, and CI repeats the check on commits and PR bodies.
  - **`pre-commit`:** rejects any staged path in `.gitignore`'s never-commit groups (`private/`, `secrets/`, `.env` files, key and certificate files, `*.local.*`), even one added with `-f`, then runs gitleaks on the staged changes.
  - **`pre-push`:** checks every outgoing commit on every branch: no never-commit paths, no AI attribution in its message, and a gitleaks scan. It also rejects a push to `main` unless every first-parent commit after the baseline in `.githooks/signed-baseline` is a signature I made (`git log --first-parent --format=%G?` is `G` for each). While that file is empty, the hook only prints a warning, so the first unsigned scaffold release can go out. I set the baseline once signing works. Set `gpg.ssh.allowedSignersFile` locally so `%G?` can check. Claude Code can't type the signing passphrase, so it can't produce those commits.
- **GitHub ruleset on `main`:** block force pushes and deletion. Don't turn on GitHub's "require signed commits": it would also reject the unsigned feature commits that come in through each signed merge.
- **CI:**
  - **Code:** `tsc --noEmit` (strict), Vitest, shellcheck.
  - **Secrets and privacy:** gitleaks, with custom rules for Healthchecks ping URLs, Discord webhook URLs, MAC addresses, and `192.168.x.x` / `172.16–31.x.x` addresses (an allowlist covers the documented examples). It also runs in the local pre-commit and pre-push hooks.
  - **Config:**
    - the compose policy and its negative tests
    - the network rules, generated from `networks.tsv`
    - `cloudflared tunnel ingress validate`
    - the rule-label lint
    - no literal image in `stacks/apps/`
    - `DRY_RUN=true` in the repo
    - every secret in `secrets-init.sh` has a revoke row
  - **Log:** a warning when code changes come without a log entry.

---

## 11. Open decisions

- [x] **D-1 / D-5a: disk encryption.** None for now; the server will be reinstalled without it (Phase 1)
- [x] OS: Debian 13, headless, unencrypted LVM, 300 GB root
- [x] Only my own solo projects are hosted; monitoring apps hosted elsewhere is deferred
- [x] No live demo; show-and-tell is a presentation
- [x] Schedule: a priority order; the project continues after Dec 13
- [x] Power: the critical timer and shutdown hook in Phase 2; the watcher in Phase 4 (Target)
- [x] **D-8: signing.** A dedicated SSH signing key with a passphrase, never in ssh-agent, plus the review gate. A FIDO2 key is a later upgrade
- [x] **D-9: plan structure.** This plan plus `docs/design/`
- [ ] **D-4: remote access.** Tailscale (optional; decide before any trip)
- [ ] **D-5: household data encryption** (before any household data). Default: a separate LUKS volume unlocked by hand. Alternatives: TPM with a signed UKI, or TPM + PIN
- [ ] **D-10: Secure Boot if "Microsoft UEFI CA 2023" never arrives** (decide by Dec 13). Keep the shim hold, or turn Secure Boot off
- [ ] Domain name
- [ ] Which solo project goes first (e.g. Focusqueue; it must need no schema changes during the course)
- [ ] Claude model, chosen by evals
- [ ] Discord channels: `#alerts` (raw), `#incidents` (agent), `#handoff`, later `#approvals`
- [ ] Power settings, after measuring the real battery runtime
- [ ] Off-site backup provider (before any photos)

---

## 12. First Claude Code session (tonight, for the Nov 15 submission)

1. **Put the files in place:**
   - `docs/PLAN.md`
   - `docs/design/*.md`
   - `docs/runbooks/reinstall-server.md`
   - `docs/reviews/README.md`
   - Your private notes go in `private/` (git-ignored). Check it's ignored before the first commit: `git check-ignore -v private/README.md` should print the matching rule.
2. **Start Claude Code with this prompt:**

> Read `docs/PLAN.md` and skim `docs/design/`. Show me your plan before writing files. Then:
> 1. Create `.gitattributes`, `.env.example`, `.claude/settings.json` and the `.githooks/` hooks (PLAN section 10). Extend the existing `.gitignore`; keep its `private/` line.
> 2. Draft a short `CLAUDE.md` from PLAN sections 1, 3–8 and 10: context, stack, structure, rules. Point to `docs/PLAN.md` and `docs/design/` for details, and include the public repo hygiene rules.
> 3. Create the folder skeleton from section 7, with a one-line README in each folder.
> 4. Write `README.md` with the one-paragraph goal and the diagram.
> 5. Draft `docs/decisions/0002-disk-encryption.md` from `docs/design/host-ops.md`.
> 6. Write the first entry in `docs/log/`.
> Don't read `private/`. Don't commit, install anything, or touch the server.

3. **Commit it yourself:**
   - Run `git config core.hooksPath .githooks`.
   - Check `git status`: nothing under `private/` should appear.
   - Commit on `develop`, then release to `main`: `git switch main && git merge --no-ff develop && git push origin main develop`. Tonight's commits don't need signatures, because the server only checks commits after the baseline you set in Phase 1.
   - Update the portfolio card.
4. **After that:** set up signing (Phase 0). From then on, feature work goes to `develop`, and only your signed merges reach `main` (section 10).
