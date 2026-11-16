# Plan reviews

The plan was reviewed three times on 2026-11-14, each time by three independent reviewers:
- **Security:** a STRIDE threat model across every trust boundary.
- **Reliability:** a pre-mortem and failure-mode analysis.
- **Consistency:** fix verification, consistency and a fact-check against official docs.

Each round's findings were merged, the high-impact claims were checked against primary sources, and the fixes were folded into `docs/PLAN.md` and `docs/design/`. The full review reports are kept privately, because they include personal scheduling and details of projects outside this repo.

## What changed as a result

**Round 1:**
- Isolated Docker networks.
- Pull-based deploys by digest.
- Socket-proxy access for the agent.
- Approvals that can't be forged.
- A dead man's switch for the monitoring.
- Backups with restore tests.
- Learning outcomes mapped to evidence.

**Round 2:**
- A single source of truth for which app version runs.
- An ordered stop and start for the stacks.
- A corrected home-network block.
- A strict compose allowlist.
- Explicit staleness alerts.
- The decision to drop full-disk encryption, with an honest threat model.

**Round 3:**
- Compose files are checked before and after resolving, in a sandbox.
- Image config is checked too.
- Networks are defined in one file.
- Controls fail closed.
- Failed deploys restore the last good version and hold the revision.
- A locally managed tunnel.
- Signed merges with a review gate before anything reaches the server.

All design decisions are recorded in `docs/PLAN.md` (section 11) and `docs/decisions/`.
