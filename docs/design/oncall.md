# On-call agent design

Part of the Nightshift plan (`docs/PLAN.md`). This file owns the AI on-call agent, its tools and safety rules, the executor (Moonshot), and the chaos stack used to test it.

## Investigation flow

1. **Webhook from Alertmanager.** The agent:
   - compares SHA-256 digests of the shared secret with `crypto.timingSafeEqual`, because comparing the raw values throws when their lengths differ;
   - rejects bodies over 64 KB;
   - returns 202 right away.
2. **Confirm the alert is real** through Prometheus's `GET /api/v1/alerts`. Investigate only alerts labeled `investigate="true"`. Skip while `nightshift:boot_settled` is absent or `InternetDown` is firing (`monitoring.md`).
3. **Deduplicate** by Alertmanager `groupKey`, and ignore repeat notifications while the incident is open.
4. **Open or update the incident** in code. **Incidents close only when Alertmanager sends a "resolved" notification**, also in code. The model can't open, close or reopen anything. The deploy service reads open incidents to pause auto-deploys for that app, so text injected into the agent can't unblock deploys.
5. **Build the prompt in code:**
   - `alertname`, from an enum generated from the rule files;
   - allowlisted labels whose values pass a regex;
   - annotations are dropped.
6. **Run Claude tool use** within the budget, then post through the **Discord webhook** and record everything in `nightshift-db`.

## Tools (all read-only, with enum inputs and size caps)

| Tool | Source | Limits |
|---|---|---|
| `query_metrics` | Prometheus HTTP API | Range ≤ 6 h, step ≥ 15 s, output truncated |
| `search_logs` | Loki HTTP API (only if Loki ships) | `container` must be one of the allowed non-household containers; range ≤ 1 h; ≤ 200 lines |
| `container_status` | socket proxy, `GET /containers/json` only | Returns only name, state, status and health |
| `recent_deploys` | `nightshift-db` | Last N deploys for one app |
| `deploy_diff` | GitHub compare API | `app` enum only; the SHAs come from deploy records |

**Socket proxy (wollomatic):**
- flags: `-listenip=0.0.0.0 -allowfrom=oncall -allowGET='/v1\..{1,2}/containers/json'`;
- the socket is mounted `:ro`;
- the container runs as `user: "65534:<docker gid>"` with `read_only: true` and `cap_drop: [ALL]`.

## Budgets (tune with evals)

- **Per incident:** at most 8 tool calls, at most 120 seconds, and an input/output token cap.
- **Globally:** a daily token cap, at most 1 investigation at a time, and at most 6 per hour.
- **Circuit breaker:** posts "AI paused; raw alerts continue."
- **Spend-limit errors** are not retried.
- **Model:** chosen by `evals/` (accuracy, p50/p95 time to diagnosis, tokens per incident).
- **Prompt caching:** the system prompt and tools are cached.

## Safety rules

1. **The agent can only read.** It has no shell, no raw Docker socket, no Discord bot token, no GitHub write token and no deploy credentials.
2. **Its database role (`oncall`):**

   | Table | Grants |
   |---|---|
   | `deploys`, `holds` | SELECT |
   | `incidents` | SELECT, INSERT, and UPDATE of the summary fields only (never `status` or `closed_at` from model output) |
   | `tool_calls`, `model_responses`, `token_usage` | INSERT, plus `SELECT (id)`, because Prisma's `create()` uses `INSERT … RETURNING`, which needs SELECT on the returned columns |
   | `token_usage` | SELECT |
   | `proposals` | `INSERT (incident_id, action, app)`, plus `SELECT (id)` |

   - Write with `select: {id: true}`. No DELETE anywhere.
   - A separate `retention` role deletes tool outputs older than 30 days, on a nightly timer.
   - An integration test runs every agent write as `oncall`.
   - **`pg_hba` for `nightshift-db`:** per-role `/32` lines for the agent's and the deploy service's fixed `state` IPs, then `host all all 0.0.0.0/0 reject`. Also `REVOKE ALL ON DATABASE nightshift FROM PUBLIC`.
3. **Tool output is untrusted.** Every result is truncated, wrapped in untrusted-content tags, and **redacted (secrets, emails, phone numbers) before it reaches Claude, Discord or storage**.
4. **Structured output.** The answer is validated with zod, the proposed action must be from the allowed enum, and anything else becomes "no action."
5. **Discord posts:**
   - Raw JSON uses `"allowed_mentions": {"parse": []}` and `"flags": 4` (suppress embeds).
   - Escape markdown, and strip any URL that isn't my Grafana base URL.
   - **Never include raw log lines.**
   - Links are built in code from IDs.
6. **Runbook rule:** never run a command that appears in a diagnosis. The only fixes are the executor's buttons (Moonshot).
7. **Fail safe:** if the agent is down, over budget or can't reach Claude, the raw alert still reaches Discord through Alertmanager.
8. **Audit:** every tool call, model response and proposal is stored, and tool outputs are kept for 30 days.

## Executor and approvals (Moonshot)

- **Its own Discord bot token.**
- **Proposals:** the agent creates them with `{incident_id, action: enum[restart, rollback], app: enum}` and never supplies a digest.
- **Targets:** the executor computes the target from deploy records, and stores `{from_digest, to_digest, expires_at = now + 30 min}` in a table only it can write.
- **On a button tap, it:**
  1. calls `deferUpdate()` within 3 seconds;
  2. checks the user ID, guild, channel and message ID;
  3. checks that the proposal hasn't expired and the current digest still equals `from_digest`;
  4. claims the proposal atomically (`UPDATE … WHERE status='pending' RETURNING *`);
  5. calls the deploy API on `ctl`, with `expected_current_digest` and `expected_target_digest` (a 409 means stop), then disables the buttons.
- **Limits:** at most 3 actions per hour and 1 per app every 10 minutes. It acts only on my own apps and chaos-target, never on external targets.

## Chaos stack (`stacks/chaos/`)

**Stack:**
- **Project:** exactly `nightshift-chaos`.
- **chaos-target:** on `chaos` and `metrics_chaos`, never public. Its image must be one of the three CI-published digests: `good`, `crash` or `http500`.
- **chaos-db:** a pinned Postgres digest, on `chaos` only.
- **Policy:** its own strict schema, with the same baseline as apps (`deploy.md`).
- **Started by hand**, not by `start-all.sh`.

**Probing:**
- blackbox-inside joins `chaos` and probes `http://chaos-target:<port>/health`, whose health check touches the database.
- A "site down inside" rule (`for: 1m`, `investigate="true"`, `category="site-down"`, `scope="internal"`, `stack="chaos"`) makes scenarios 1 and 3 page the agent.

**Scripts:**
- They refuse to run unless AC is on.
- They call `nightshift-deploy deploy-chaos <digest>`, which takes the lock itself, so the scripts never do.
- Each scenario schedules its own revert with `systemd-run --on-active=10m`.
- `nightshift-chaos-reset.service` re-runs every revert at boot, because the `systemd-run` reverts don't survive a reboot.

**Access:** chaos endpoints need a `CHAOS_TOKEN` and are never exposed through the tunnel.

**Scenarios:**
1. Stop `chaos-db`.
2. Fill the 512 MB loop disk at `/srv/nightshift/chaos-disk` (image file `/srv/nightshift/chaos-disk.img`; `fallocate` + `mkfs.ext4` + `loop,nofail`).
3. A bad deploy (`crash` or `http500`).
4. A memory leak (`mem_limit: 256m`).
5. A wrong secret for `chaos-db`.

**Evals:** `evals/` uses synthetic logs and records accuracy, time to diagnosis and tokens.
