# Deploy design

Part of the Nightshift plan (`docs/PLAN.md`). This file owns how app images are built, checked, deployed, rolled back and migrated. The summary is in `docs/decisions/0001-deploy-model.md`.

## Build (in each app's repo)

- **PR and test jobs** get `permissions: {contents: read}` and run `npm ci --ignore-scripts`.
- **Branches:** each app repo uses the same `main` + `develop` model as this repo. Pushes to `develop` and feature branches run tests and build the image without publishing it.
- **The publish job** runs **only on a push to `main`**. It builds the image, pushes `:sha-<git>`, and moves `:main`.
- **Image labels:**
  - `org.opencontainers.image.revision`: the full 40-character commit SHA.
  - `io.nightshift.migrations`: a hash of the migrations folder.
- **Registry:** packages are **public** on GHCR, so the server holds no registry token.
- **Supply chain:**
  - Actions are pinned to full commit SHAs, with `permissions: {}` by default and no `pull_request_target`.
  - Renovate covers Actions, base images and pinned images, with `minimumReleaseAge: "3 days"` and no npm automerge.
  - A weekly rebuild runs on a weekday afternoon, with `trivy image --exit-code 1 --severity CRITICAL`.
- **Build provenance (Target, Phase 4 if time allows):**
  - CI runs `actions/attest-build-provenance`.
  - Before `up`, the deploy service runs `gh attestation verify oci://… --repo jbarra2/<app> --signer-workflow jbarra2/<app>/.github/workflows/publish.yml --source-ref refs/heads/main --deny-self-hosted-runners`, and takes the revision from the attestation instead of the label.
  - This adds a one-member `egress_deploy` network.

## What runs: one source of truth

- **`/var/lib/nightshift/deploy/<app>.json`** is the resolved, validated compose file of the version that last passed its health check.
- **`<app>.prev.json`** is the one before it.
- **Writes are atomic:** temp file, fsync, rename. Only the deploy service writes them.
- **Every start of an app** (deploy, rollback, `start-all.sh`, runbooks) first re-validates the file:

  ```
  docker run --rm --network none <deploy image> validate < <app>.json
  ```

  then runs exactly:

  ```
  env -i PATH="$PATH" docker compose --env-file /dev/null --project-directory /var/lib/nightshift/deploy \
    -p app-<app> -f /var/lib/nightshift/deploy/<app>.json up --wait --wait-timeout 180 --no-build --no-recreate
  ```

  - If the file is missing or fails validation, the app is skipped and an alert fires. It never falls back to a tag.
  - Deploys and rollbacks drop `--no-recreate`, so the new config is applied.
- **App source files** (`stacks/apps/<app>/compose.yml`) use `image: ${IMAGE:?set by deploy service}`. CI rejects a literal tag or digest there.
- **Infra stacks** use `-p nightshift-<stack>`, and their images are pinned in the repo.
- **Phase 1 check:** confirm that `compose config --format json` output can be fed back with `-f`, and that a second `config` run on it gives identical output.

## Deploy service

- **On startup:**
  - waits for `/run/nightshift/deploy/boot-complete`;
  - marks leftover `in_progress` rows as `interrupted`;
  - compares what's running with the state files.
- **Polling:** every 60 seconds, via the Docker API (`GET /distribution/ghcr.io/jbarra2/<app>:main/json`), it reads each app's `:main` digest.
- **It skips an app when any of these is true:**
  - `/run/nightshift/deploy/deploy.frozen` exists;
  - the app has an open incident (it reads `incidents`);
  - the digest previously failed;
  - it can't read the holds (fails closed).

### On a new digest
1. **Lock:** `flock -w 60 /run/nightshift/deploy/deploy.lock`. The file is created once by tmpfiles and never deleted. A `DeployLockHeldTooLong` alert fires after 15 minutes.
2. **Pull:** `timeout 600 docker pull <ref@digest>`.
3. **Image checks**, from `docker image inspect --format '{{json .Config}}'`. Reject:
   - a non-null `Volumes`;
   - labels matching `^(nightshift\.|io\.nightshift\.(?!migrations$)|com\.docker\.compose\.|socket-proxy\.)`;
   - a `StopSignal` other than SIGTERM, SIGINT, SIGQUIT or empty;
   - a revision label that doesn't match `^[0-9a-f]{40}$`.
4. **Holds:** if the revision is held, stop and post a "Needs you" line.
5. **Migrations:** if `io.nightshift.migrations` differs from the hash last recorded by `nightshift-deploy migrated`, stop. Alert "migration needed" once per revision.
6. **Raw YAML check** of `stacks/apps/<app>/compose.yml` (below).
7. **Resolve in a sandbox**, with nothing to read and no network:

   ```
   docker run --rm --network none --read-only -v /opt/nightshift/stacks/apps/<app>/compose.yml:/in/compose.yml:ro \
     <deploy image> compose -f /in/compose.yml --env-file /dev/null -p app-<app> config --format json --no-env-resolution
   ```

   with `IMAGE=<ref@digest>` passed in. Reject any `$` left in values. Run `config` again on the output and require identical results.
8. **Validate** the result against the schema (below).
9. **Deploy** with the "What runs" command (without `--no-recreate`), wrapped in `timeout 300`.
10. **Health check.**
11. **Success:**
    - move `<app>.json` to `<app>.prev.json`, unless that revision is held;
    - write the new `<app>.json`;
    - record app, digest, revision, time and result in `nightshift-db`.
12. **Failure:**
    - re-`up` the existing `<app>.json` and record `restored_last_good`;
    - auto-hold the failed revision (`reason=auto:healthcheck`);
    - set `nightshift_deploy_last_result{app}` to 0, which fires `DeployFailed`.

**Image retention:** keep the current image, the last-known-good one, any hold target, and the 2 before them. Never `docker image prune -a`.

**Scope:** it never deploys or updates itself, infra stacks, cloudflared or the databases. Those go through `nightshift-apply` and the maintenance runbook (`host-ops.md`).

**Dumps:** `pg_dump` runs as `docker exec` in the Postgres container, as the app's `<app>_migrate` owner role, so the deploy service never joins an app's database network.

## Compose policy (`policy/`)

The policy code is a TypeScript package. It's built into the deploy image and run by CI, and never read from the checkout at runtime.

### Raw YAML check (before resolving)
- Parse with aliases and merge keys turned off.
- The top level allows only `services`, `networks`, `volumes` and `secrets`.
- **Rejected anywhere:**
  - `include`, `extends`, `env_file`, `label_file`, `configs`, `provider`;
  - `pre_start` and `post_start`, `use_api_socket`, `volumes` of `type: image`;
  - `profiles`, except `profiles: ["migrate"]` on a service named `migrate`;
  - any `x-*` key except `x-nightshift-no-healthcheck`.

### Schema (on the resolved JSON; `.strict()` at every level)
- **Top-level `networks`:** keys within {`edge_<app>`, `metrics_<app>`, `db_<app>`}. Each value is exactly `{name: <the same name>, external: true}`, with names checked against `networks.tsv`.
- **Top-level `volumes`:** keys match `^<app>_[a-z0-9_]+$`. Each value is exactly `{name: "app-<app>_<key>"}`, with no `external`, `driver`, `driver_opts` or `labels`.
- **Top-level `secrets`:** `file:` paths are `path.resolve`d first, then must start with `/etc/nightshift/secrets/<app>/`. The `migrate` service may also use `/etc/nightshift/secrets/<app>-migrate/`.
- **Per service:**
  - **image:** must match `^ghcr\.io/jbarra2/<app>@sha256:[0-9a-f]{64}$`.
  - **networks:** each entry is `null` or `{}`. No `aliases`, `ipv4_address`, `mac_address`, `driver_opts` or `interface_name`.
  - **volumes:** only `type: volume` with a declared source (no bind, tmpfs or image volumes).
  - **labels:** the only Nightshift label allowed is `nightshift.logs: "true"`.
- **Required baseline on every service:**
  ```yaml
  user: "2xxxx:2xxxx"            # matches ^2\d{4}:2\d{4}$; CI checks it's unique across apps
  read_only: true
  tmpfs: ["/tmp:size=64m"]
  cap_drop: [ALL]
  security_opt: ["no-new-privileges:true"]
  mem_limit / pids_limit / cpus  # required
  healthcheck:                    # every field required: interval >= 10s, timeout <= 10s,
                                  # retries <= 10, start_period <= 300s
  stop_grace_period: "<= 30s"
  restart: unless-stopped
  ```
  - `x-nightshift-no-healthcheck: <reason>` is allowed only together with `healthcheck: {disable: true}`.
- **Everything else is rejected,** including:
  - `privileged`, `devices`, `cap_add`, `sysctls`, `ulimits`;
  - host namespaces (`pid`, `ipc`, `uts`, `userns_mode`, `cgroup`), `network_mode`, `volumes_from`;
  - `extra_hosts`, `dns`, `build`, `logging` and published `ports`.
- **Project names:** must match `^[a-z][a-z0-9-]{1,30}$`, and may not use a reserved name (`nightshift*`, `app-postgres`, and so on).

### Other stacks
- **Chaos** has its own strict schema (`oncall.md`).
- **Infra stacks** are checked only in CI, against a reviewed `policy/exceptions.yml` keyed by `stack/service`. CI fails on any unlisted exception and on any unused one. Infra services also need `cap_drop: [ALL]` unless the file lists the capabilities they add back.

### Phase 1 negative tests
Each must be rejected:
- a renamed external network;
- an external volume from another project;
- `..` in a secret path;
- a shared UID;
- `env_file`, `label_file`, `include oci://…`, `extends file:`, `configs file:/`;
- a secret with an `environment:` source;
- `pre_start` with `privileged`, `use_api_socket`, `provider`, `volumes type: image`;
- an image with `VOLUME`;
- `HEALTHCHECK --interval=1ms` inherited from the image;
- joining `state`;
- a reserved project name.

## Rollback and holds

- **Rollback:**
  - re-validates and `up`s `<app>.prev.json`, which becomes the current `<app>.json`;
  - auto-holds the revision that was current;
  - **never rotates `.prev.json`** (so a second rollback can't land on the bad build);
  - is refused if the deploy being rolled back applied migrations.
- **Holds:**
  - are keyed on the git revision;
  - release **only** with `nightshift-deploy release <app>`;
  - a newer revision during a hold adds a "Needs you" line instead of deploying.
- **No automatic rollback** in v1, beyond restoring the last good file after a failed health check.

## Control: the `nightshift-deploy` CLI

`sudo nightshift-deploy <verb> …` is installed by `nightshift-update`. It runs `docker compose -p nightshift-platform -f /opt/nightshift/stacks/platform/compose.yml exec deploy node cli.js <verb> …`.

- **Verbs:** `status`, `rollback <app>`, `hold <app>`, `release <app>`, `freeze`, `unfreeze`, `migrate <app> <digest>`, `migrated <app> <hash>`, `deploy-chaos <good|crash|http500>`.
- **Locking:** the CLI takes the lock itself, so scripts that call it never do.
- **The HTTP API** comes with the executor (Moonshot), on the internal `ctl` network:
  - a token per caller, scoped to specific endpoints;
  - `expected_current_digest` and `expected_target_digest` on every action;
  - 409 on a mismatch.

## Migrations

- **Expand/contract only.** Each release must work with the previous release's code.
- **Database roles:**
  - `<app>` has DML only (no `CREATE`).
  - `<app>_migrate` owns the schema. Its secret is in `/etc/nightshift/secrets/<app>-migrate/`, which only the `migrate` service may mount.
- **The `migrate` service** has `profiles: ["migrate"]`, so `up` never starts it.
- **Runbook (`docs/runbooks/migrate.md`, by hand in v1):**
  1. `nightshift-deploy freeze`
  2. `pg_dump -Fc` as `<app>_migrate` (keep 3)
  3. `nightshift-deploy migrate <app> <digest>`: resolves with `--profile migrate` in the sandbox, validates, then runs `run --rm migrate`
  4. `nightshift-deploy migrated <app> <hash>`
  5. `nightshift-deploy unfreeze`. The poller then deploys normally.
- **Interrupted migrations:** `prisma migrate resolve`.
- **Target:** the deploy service runs these steps itself.
