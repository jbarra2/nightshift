# Nightshift

A self-hosted home lab on a spare ThinkPad T480s, with an AI on-call engineer. The server hosts my own projects on the public web through Cloudflare Tunnel, deploys them by image digest when I push to GitHub, monitors everything around the clock, and comes back on its own after power cuts and reboots. When an alert fires, an agent investigates with read-only tools and posts a likely cause and a proposed fix to Discord.

**This repository is public, history included.** Follow "Public repo hygiene" below in code, docs, `LOG.md`, commit messages and screenshots.

## Where things are

- `docs/PLAN.md`: goal, stack, structure, schedule (section 9) and open decisions (section 11). It and `docs/design/` are the source of truth.
- `docs/design/`: one document per area. PLAN section 8 lists what each one owns. Read it before changing that area.
- `docs/decisions/`: decision records. `docs/runbooks/`: step-by-step procedures. `docs/reviews/README.md`: only a summary of the plan reviews.
- `LOG.md`: the build log.

## Stack

- **Server:** Debian 13, headless, with systemd; Docker Engine and Compose; Cloudflare Tunnel. Host scripts are Bash and systemd units.
- **My services** (`deploy/`, `oncall/`, `executor/`): TypeScript on Node.js 24 with Express 5, zod 4, Prisma 7 and Vitest. The on-call agent uses the Claude API.
- **Monitoring:** Prometheus, Alertmanager, Grafana, Loki and Alloy, Healthchecks.io, and Discord.
- Every version is pinned in PLAN section 5.

## Structure

PLAN section 7 has the full tree, and each folder has a one-line README.
- `host/`: scripts and units for the server.
- `policy/`: the compose policy.
- `stacks/`: one Compose project per folder.
- `deploy/`, `oncall/`, `executor/`: my services.
- `apps/chaos-target/`, `chaos/`, `evals/`: the chaos app, the break-it scripts, and the evals.

Hosted apps live in their own repos, and this repo never holds a tag or digest for them.

## Branches and commits

- `main` is the source of truth, and the server deploys only from it. `develop` is where tested work rests before release. Feature branches (`feature/<topic>`) come off `develop`.
- Claude Code may commit on feature branches and `develop`, and merge feature branches into `develop`. Commits carry no AI attribution.
- **Pushes are mine.** Claude Code never pushes, and never commits to, merges into, rebases, moves or switches to `main`.
- Releases are mine too: a signed `--no-ff` merge of `develop` into `main` (PLAN section 10).
- Never skip or switch off the git hooks.

## Rules

- **Secrets:** never read, print or commit `.env` files or secrets. Use the variable names in `.env.example`. On the server, secrets are files under `/etc/nightshift/secrets/`, never environment values.
- **One home per fact:** when you change a design detail, update its design doc in the same commit.
- **Change flow:**
  - Every change goes through the repo. The only server-side state is listed in `docs/design/host-ops.md`.
  - Host scripts are installed by `nightshift-update`, never run from the checkout.
- **Networks:**
  - Follow `docs/design/network.md`.
  - Networks come only from `host/setup/networks.tsv`, and compose files declare them `external: true`.
  - Ask before adding a network.
- **Containers and Compose:**
  - Secrets are files: Compose `secrets:` plus `*_FILE` settings, never `environment:`.
  - Admin ports are published on `127.0.0.1` only.
  - Infra images are pinned by digest or exact tag. App compose files never contain a tag or digest.
  - Bind-mount directories, not single files (long syntax, `create_host_path: false`).
- **Bash:** validate every value before using it in arithmetic or a command.
- **Code:** TypeScript in strict mode, with Vitest tests. Migrations are expand/contract only.
- **Ask before** adding a container, a network, or a `dependencies` entry.
- **Hands off the server:**
  - Never touch `stacks/pihole/` or `stacks/nas/` in chaos or eval work. Chaos scripts only target the `nightshift-chaos` project.
  - Never, without me: run the power watcher or the critical timer live, trigger a shutdown or reboot, update firmware, or run chaos on the server.
  - Nightshift's runtime never writes to external targets.
- **`private/`** holds my private notes. Read it only when I ask, and never copy anything from it into tracked files.

## Public repo hygiene

- **Fine to publish:** my name, school, GitHub username and commit email; the architecture and design; placeholder examples.
- **Never commit** any of the following, in code, docs, `LOG.md`, commit messages, issues or screenshots:
  - **Schedules:** travel or away dates, and when the house is empty.
  - **The home network:** real LAN addresses and ranges, router details, MAC addresses, Wi-Fi names.
  - **Machine identifiers:** SSH host fingerprints, serial numbers.
  - **Accounts:** Discord server, channel or user IDs; webhook, Healthchecks, tunnel or other credential URLs and files.
  - **Other people:** names, details and data of companies, clients, teammates or other projects; anything about the people in my home or their data.
  - **Real data:** real log lines, IPs or emails other than mine. Evals and tests use synthetic data only.
- Those details live in `/etc/nightshift/` on the server or in `private/`.
- Screenshots are cropped or blurred: no IPs, IDs, tokens, URLs with secrets, or real user data.
- Before a push, check the diff for all of the above. A pushed secret stays in git history, so rotate it; deleting it isn't enough.

## Enforced mechanically

- **`.claude/settings.json`:**
  - no AI attribution;
  - denies pushes, switching to or moving `main` with `switch`, `checkout`, `branch` or `update-ref`, skipped hooks, forced adds, `git clean`, `gh auth`, and reading `.env` files or `secrets/`;
  - asks before `ssh`, `gh`, installing packages, discarding work, reading `private/`, and editing `.claude/`, `.githooks/`, `.github/workflows/`, `.gitignore` or `.gitattributes`.
- **`.githooks/`** (turn on with `git config core.hooksPath .githooks`):
  - `commit-msg` refuses AI attribution;
  - `pre-commit` refuses never-commit paths and scans the staged changes with gitleaks;
  - `pre-push` re-checks every outgoing commit, and requires good signatures on `main` after the baseline (until `signed-baseline` is set, that check only warns);
  - `sh .githooks/test.sh` tests them.
- **Behind these:** no real secrets on this workstation, a signing key that is never in ssh-agent, npm install scripts turned off, and a server that installs only signed, reviewed changes.

## Build log

`LOG.md` gets one numbered entry per piece of work. Each entry has:
- its date;
- **Asked:** what I asked, in plain words, not word for word;
- **What came back / what changed**;
- **Next**.

Not every chat message needs an entry, and chats about my machine or tool settings stay out. The heading names the tool, such as Claude Code. Keep entries within the hygiene rules above, name no other project, and say what was fixed, not what is still open.
