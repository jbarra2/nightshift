# External targets design (deferred)

Part of the Nightshift plan (`docs/PLAN.md`). This covers watching apps that are hosted somewhere else, for example on a PaaS such as Render. It's **deferred** and is only done with the app owner's written approval. This is the design for when it resumes.

## Levels

**Level 1:** a public `/health` endpoint that returns no data, probed about once a minute by blackbox-outside.
- **Check the host's free-tier rules first.** On some free tiers, a once-a-minute probe keeps the app awake and uses up its free hours.

**Level 2** (needs the owner's written OK): read deploys, logs and metrics through the host's API, with a **read-only key scoped to that one app or workspace**.
- **Where the key lives:** in a tiny `<host>-reader` service with its own egress network, never in the agent.
- **Logs:** fetched on demand, and **never written to Loki**.
- **No inbound webhooks.**
- **Audit and Discord:** audit records store only a hash of what was fetched, and Discord posts about external targets show status only.

**Level 3** (needs an explicit OK for AI processing): the agent gets read-only tools for the target, with redaction.

## Rules

- **Always read-only.** Nightshift's runtime never writes to external targets.
- **Changes to an external app happen in its own repo.**
- **The host's built-in alerts stay on.**
- **The executor never acts on external targets.**
- **Real target configs and owner details never go in this repo.** They live in `/etc/nightshift/targets/` on the server. `targets/example.yml` shows the format with placeholder values.
