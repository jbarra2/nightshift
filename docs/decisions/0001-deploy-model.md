# 0001: Pull-based deploys by image digest

- **Status:** accepted on 2026-11-14, and refined in the three plan reviews (`docs/reviews/README.md`).
- **Details:** `docs/design/deploy.md`. This record is a summary; that document owns the facts.

## Context

A push to GitHub should put my apps live with no one at the server, and there must be strict checks on what a deploy may do (PLAN goal 2). The server is a laptop at home with no open router ports.

## Options

1. **CI pushes the deploy into the server.** Ruled out by the architecture: the laptop pulls, and nothing pushes in (PLAN section 4).
2. **Kubernetes (k3s) with GitOps (Flux or Argo CD).** Kept as a Moonshot option (PLAN section 5).
3. **A deploy service on the server that pulls each app by digest and checks it first.**

## Decision

Option 3.

- **Build:** each app's own repo builds its image. Only a push to `main` publishes it, as `:sha-<git>`, and moves `:main`. The image is labelled with its full commit SHA and a hash of its migrations.
- **Registry:** images are public on GHCR, so the server holds no registry token.
- **Polling:** the deploy service reads each app's `:main` digest through the Docker API every 60 seconds. It is the only container that writes to Docker (the host's own units are the other writers, under the same deploy lock), and in version 1 it has no internet access.
- **Checks on a new digest:** take the deploy lock, then pull by digest and check the image config. Then check holds and the migrations gate, run the raw-YAML check, resolve the compose file in a sandbox with no network, and validate the result against a strict schema.
- **Deploy:** `up` by digest, then a health check.
- **What runs:** the validated, resolved compose file of the last good deploy, `/var/lib/nightshift/deploy/<app>.json`, is the one source of truth. Every start re-validates it, and it never falls back to a tag.

## Consequences

- **Nothing reaches the server from outside to deploy.** App compose files hold `image: ${IMAGE:?}`, and this repo never holds a tag or digest for a hosted app.
- **A reboot brings back the same digests,** because every start uses the validated file.
- **A failed health check restores the last good file** and holds the failed revision. Version 1 has no automatic rollback beyond that. `nightshift-deploy rollback` and `release` are manual.
- **Deploys pause on their own when:**
  - deploys are frozen;
  - the app has an open incident;
  - the digest failed before;
  - the holds can't be read (fails closed).
- **Migrations are expand/contract.** In version 1 they run by hand from a runbook, and a deploy that needs one stops with "migration needed".
- **The deploy service never deploys** itself, the infra stacks, cloudflared or the databases. Those go through `nightshift-apply` and the maintenance runbook (`docs/design/host-ops.md`).

## Revisit

- **Target:** build provenance with attestations (which gives the deploy service a one-member `egress_deploy` network), and migrations run by the deploy service itself.
- **Moonshot:** the deploy API for the executor's approvals, and k3s with GitOps.
