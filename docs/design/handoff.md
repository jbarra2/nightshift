# Morning handoff design

Part of the Nightshift plan (`docs/PLAN.md`). The handoff is part of the on-call agent (`oncall.md`).

## When

- 8:00 a.m. daily, covering everything since the previous handoff.
- It posts even after a quiet night.
- Then it pings its Healthchecks.io check, **but only after Discord returns 2xx**.

## Contents, in this order

1. **Needs you:**
   - **Backups and updates:** failed backups; a pending or deferred reboot, with the reason; security updates pending more than 3 days; dpkg problems; a held shim update with a newer version waiting.
   - **Stacks and deploys:** a stack that's down; compose drift waiting for `nightshift-apply`; deploys frozen; a held revision with a newer one waiting; "migration needed" stops.
   - **Safety controls:** the LAN block missing; the server not on the home network; secrets with bad permissions; a boot with no maintenance or power event behind it.
   - **Housekeeping:** disk over 70%; silences older than 2 hours.
   - **Later:** pending proposals (Moonshot); TLS certificates within 14 days of expiry (after Dec 13).
2. **Incidents:** count, status, and links to their Discord threads.
3. **Deploys:** what shipped, health check results, holds and restores.
4. **Backups:** last run, result and size, and the last restore test.
5. **Health:** peak disk, memory and temperature; restarts; power events; battery health.
6. **AI usage:** tokens used.

## How it's built

- **Facts come from queries** (`nightshift-db`, the Prometheus API, textfile metrics, the power events file), formatted with a fixed template.
- **Claude writes only a two-sentence summary** from the same data. If that call fails, the handoff posts without it.

## Example

```
Nightshift handoff · Tue Dec 1 · 8:00 a.m. – 8:00 a.m.
One incident overnight: chaos-target started returning errors after the 2:10 a.m.
deploy. The deploy service restored the last good version and held the revision.

Needs you
• Review incident #0142 (chaos-target)
• Revision 3f2a91c is held; release it with nightshift-deploy release chaos-target

Incidents   1 open → #incident-0142
Deploys     chaos-target 3f2a91c · health check failed · restored last good
Backups     3:00 a.m. ✓ 4.2 GB · last restore test Nov 25
Health      disk 47% · max temp 61°C · 0 restarts · no power events · battery 78% health
AI usage    18k tokens
```
