# Nightshift

A self-hosted home lab on a spare ThinkPad, with an AI on-call engineer.

Nightshift turns a spare ThinkPad T480s into a small production server. It hosts my own projects on the public web, each at its own URL through Cloudflare Tunnel with no open router ports, and deploys them automatically by image digest when I push to GitHub, with strict checks on what a deploy may do. It monitors everything around the clock, including the monitoring itself. When an alert fires, an AI on-call agent investigates with read-only tools and posts a likely cause and a proposed fix to Discord, and every morning it writes a handoff about the night before and what needs me. It survives power outages and reboots cleanly, and comes back on its own.

## Architecture

<!-- Copied from docs/PLAN.md section 4. Update both together. -->

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

## More

- [docs/PLAN.md](docs/PLAN.md): the plan, the schedule and the decisions.
- [docs/design/](docs/design/): how each part works.
- [docs/decisions/](docs/decisions/): decision records.
- [LOG.md](LOG.md): the build log.
