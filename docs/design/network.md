# Network design

Part of the Nightshift plan (`docs/PLAN.md`). This file owns: Docker networks, the LAN block, the tunnel, admin access and remote access.

## Principles

- **Apps get no route out.** Each app's networks are internal. They can't reach the internet, the LAN, or each other.
- **One service per egress network.** Anything that needs the internet gets its own `egress_<service>` network, with only that service on it.
- **Only Prometheus bridges zones.** It's the only service allowed on both app-facing and control-plane networks.
- **One source of truth.** `host/setup/networks.tsv` holds every network's settings. Compose files only refer to those networks.

## `host/setup/networks.tsv`

Columns: `name`, `class` (`app`, `control`, `egress`, `household`), `internal` (yes/no), `subnet`, `gateway`, `gateway_mode` (`nat` or `isolated`), and fixed IPs (`service=ip,...`).

- **`start-all.sh` creates the networks:** before any stack starts, it runs an idempotent `docker network create [--internal] --subnet … --gateway … -o com.docker.network.bridge.gateway_mode_ipv4=<mode> --label io.nightshift.managed=true <name>` for each row.
- **Compose files never create networks:** every compose file declares the networks it uses as `external: true`, with `name:` equal to the key.
- **CI generates from the same file:** the network rules, the compose policy's allowed names (`deploy.md`), and `pg_hba.conf`.
- **Subnet ranges:**
  - Nightshift networks use `10.200.1.0/24` through `10.200.255.0/24`.
  - Per-app networks start at `10.200.100.0/24`.
  - Household networks use `10.199.0.0/23`.
  - Docker's own pools (`daemon.json`) are `10.201.0.0/16` and `bip 10.200.0.1/24`.
  - None of these may overlap the home LAN or Tailscale's `100.64.0.0/10`.
- **Gateway mode:** internal networks use `isolated` (Docker 28+: no address on the host), except `probe`, which keeps `nat` so Prometheus can reach node_exporter on the host.

## Networks

| Network | Class | Internal | Members |
|---|---|---|---|
| `edge_<app>` | app | yes | cloudflared, `<app>`, blackbox-inside |
| `metrics_<app>` | app | yes | Prometheus, `<app>` |
| `db_<app>` | app | yes | `<app>` (and its `migrate` service), app-postgres |
| `chaos` | app | yes | chaos-target, chaos-db, blackbox-inside |
| `metrics_chaos` | app | yes | Prometheus, chaos-target |
| `probe` | app | yes (`nat` gateway) | Prometheus, blackbox-inside, blackbox-outside |
| `obs` | control | yes | Prometheus, Alertmanager, Loki, Grafana, Alloy, on-call agent |
| `state` | control | yes | nightshift-db, deploy service, on-call agent, (executor) |
| `sockproxy` | control | yes | the agent's socket proxy, the on-call agent |
| `sockproxy_alloy` | control | yes | Alloy's socket proxy, Alloy (Target) |
| `cadvisor` | control | yes | cAdvisor, Prometheus |
| `admin` | control | no | Grafana only (for its `127.0.0.1` port) |
| `ctl` | control | yes | deploy API, executor (Moonshot) |
| `tunnel_egress` | egress | no | cloudflared only |
| `egress_oncall` | egress | no | on-call agent only (Discord, Anthropic, GitHub) |
| `egress_alertmanager` | egress | no | Alertmanager only (Discord, Healthchecks); also carries its `127.0.0.1` port |
| `egress_blackbox` | egress | no | blackbox-outside only |
| `egress_executor` | egress | no | executor only (Moonshot) |
| `household`, `household_db` | household | no / yes | Pi-hole, Samba, Immich (after Dec 13) |

**Who has no internet at all:**
- apps, the `migrate` services and both Postgres instances;
- Prometheus, Loki, Alloy, cAdvisor and the socket proxies;
- **the deploy service.** It polls digests through the Docker API (`GET /distribution/<image>/json`), which dockerd answers by asking the registry. dockerd also does the pulls.

**Practical consequences:**
- **Bake in anything that would download at runtime:** Prisma engines go in the app images, with `CHECKPOINT_DISABLE=1`. Grafana plugins are provisioned, not installed at runtime.
- **Containers use the host's clock**, so only the host needs NTP.
- **A port can't be published from a container on internal networks only.** That's why Grafana has `admin`, and Alertmanager publishes through its egress network.

## Network rules (CI enforces all of them)

1. **Every network has exactly one class**, and unknown names fail.
2. **Apps** are only on their own `edge_<app>`, `metrics_<app>` and `db_<app>`.
3. **Each `egress_*` network has exactly one member.**
4. **Only Prometheus** may be on both an `app` network and a `control` network.
5. **Grafana never shares a network with the deploy service.**
6. **Names are unique on every network:**
   - an app's service name equals the app name;
   - app files may not set `aliases`, `hostname`, `container_name`, `ipv4_address` or `mac_address`;
   - CI fails on any duplicate name on a shared network.
7. **Every cloudflared ingress hostname maps to exactly one service**, and the list ends with `http_status:404`.
8. **Every subnet is inside its class's range.**

## Blocking containers from the home network

**`nightshift-lanblock.service`** (`Type=oneshot`, `RemainAfterExit=yes`, `Before=docker.service`) loads a separate nftables table. It's independent of Docker's own chains, survives Docker restarts, and doesn't duplicate on re-runs. Check the file with `nft -c -f`.

```
# /etc/nightshift/lanblock.nft (written by host/setup/lanblock.sh)
table inet nightshift
delete table inet nightshift
table inet nightshift {
  set docker4  { type ipv4_addr; flags interval; elements = { 10.199.0.0/23, 10.200.0.0/15 } }
  set private4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } }
  chain lan_block {
    type filter hook forward priority filter - 10; policy accept;
    ip saddr @docker4 ct direction original ct original ip daddr != @docker4 ct original ip daddr @private4 counter drop
    meta nfproto ipv6 iifname { "br-*", "docker0" } counter drop
  }
}
```

- **What it blocks:** connections a container *starts* toward any private, link-local or tailnet address, by original destination. That includes the router, the cable modem, other LAN hosts, and the host's own LAN IP on published ports.
- **What still works:** replies to connections that come in from the LAN.
- **IPv6:** forwarding from container bridges is dropped.
- **Household consequence:** Pi-hole's upstream DNS must be public resolvers (`1.1.1.1`, `9.9.9.9`), never the router.

**Fail closed.** Docker refuses to start without the table, but a reload of the table doesn't restart Docker.

```ini
# /etc/systemd/system/docker.service.d/10-lanblock.conf
[Unit]
Wants=nightshift-lanblock.service
After=nightshift-lanblock.service
[Service]
ExecStartPre=/usr/sbin/nft list chain inet nightshift lan_block
```

- Reload with `nft -c -f F && nft -f F`, never a unit restart.
- **Never enable Debian's stock `nftables.service` config.** Its `flush ruleset` wipes Docker's rules.
- A 5-minute timer writes `nightshift_lanblock_loaded`, and `LanBlockMissing` alerts on `== 0 or absent(...)` (`monitoring.md`).

**Container-to-host traffic** goes through INPUT, which ufw handles:
- default-deny;
- SSH only from the LAN CIDR (and later the tailnet);
- port 9100 only from Prometheus's fixed `probe` IP;
- never `allow from 172.16.0.0/12`.

**Acceptance test (Phase 1, re-run after `systemctl restart docker` and after household services go in).**

From **every non-internal network** (`admin`, `tunnel_egress`, each `egress_*`) and from `docker run --rm alpine` (the default bridge), all of these must **fail**:
- the router;
- `192.168.100.1`;
- another LAN host;
- a tailnet IP;
- the host's LAN IP on ports 22, 53 and 445.

From an app container, `wget https://example.com` and `nslookup example.com` must also fail.

These must still work:
- the tunnel serves the app;
- `ssh -L` reaches Grafana.

## Public traffic: a locally managed tunnel

**Why locally managed:** with a token, a tunnel is *remotely managed*, and its hostnames come from Cloudflare's dashboard. A locally managed tunnel takes them from the repo, so the hostname rules above are actually enforced.

- **Setup on Windows:** `cloudflared tunnel login`, then `cloudflared tunnel create nightshift`. `cert.pem` stays on Windows.
- **Credentials:** copy `<UUID>.json` into `/etc/nightshift/secrets/cloudflared/`.
- **Ingress:** `stacks/edge/config.yml` lists one hostname per public app (`service: http://<app>:<port>`) and ends with `- service: http_status:404`. CI runs `cloudflared tunnel ingress validate`.
- **Run:** `cloudflared tunnel --config /etc/cloudflared/config.yml --metrics 127.0.0.1:20241 run`. The metrics and diagnostics server would otherwise listen on all addresses inside the container and serve config and pprof data to every app.
- **Trusting the client IP:** apps trust `CF-Connecting-IP` only when the request comes from cloudflared's fixed IP on `edge_<app>`.
- **On theft:** delete the tunnel in Cloudflare, which kills its credentials.
- **Rate limiting:** `express-rate-limit` keyed on `CF-Connecting-IP`, plus a Cloudflare rate-limiting rule per hostname.

## Admin access

- **Published on `127.0.0.1` only:**
  - Grafana on 3000;
  - Alertmanager on 9093.
- **From Windows:** `ssh -L 3000:127.0.0.1:3000 nightshift`.
- **Host scripts** call `amtool --alertmanager.url=http://127.0.0.1:9093 --http.config.file=/etc/nightshift/secrets/amtool/http.yml`.
- **Prometheus** has no published port. Query it through Grafana's Explore view.
- **Never public:** admin tools (Prometheus, Alertmanager, Loki, the socket proxies, the deploy service, household admin pages) never get a public hostname.

## Remote access (optional, D-4)

Tailscale accepts tailnet traffic ahead of ufw by default, so the tailnet policy is the real filter.
- **Policy:** only my devices may reach `tag:server:22`, with no default allow-all and nothing that lets `tag:server` start connections.
- **Settings:** Tailscale SSH off, device approval on.
- **Done when:** `nmap -p- <tailnet IP>` from Windows shows only port 22.
- **If the laptop is stolen:** delete the node, because tagged nodes don't expire.
