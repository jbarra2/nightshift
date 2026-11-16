# 0002: No full-disk encryption on the server, for now

- **Status:** accepted on 2026-11-14 (D-1 and D-5a in `docs/PLAN.md` section 11).
- **Details:** `docs/design/host-ops.md`, "Disk encryption". This record is a summary; that section owns the facts.

## Context

The server is a laptop that runs unattended around the clock. It has to come back on its own after power outages and reboots (PLAN goal 6), with nobody at the keyboard.

## Options

1. **Full-disk encryption with a passphrase at boot.** Every reboot and every outage would wait at the prompt until someone typed it, so the server couldn't come back on its own.
2. **Full-disk encryption unlocked by the TPM at boot (Clevis).** This keeps unattended reboots, but it brings:
   - update holds;
   - re-binding after boot-chain updates;
   - boot hardening;
   - the risk of the server waiting at a passphrase prompt anyway.

   Even then, a skilled thief with the powered-off laptop could still get the key.
3. **No full-disk encryption,** with every secret on the server revocable and a written theft response.

## Decision

Option 3. The server is reinstalled on unencrypted LVM with `docs/runbooks/reinstall-server.md`.

## Consequences

- **Anyone who takes the laptop can read the disk.** I accept this for my own portfolio projects, because:
  - every secret on the server is revocable;
  - the Anthropic workspace has a spend limit.
- **Restic's encryption protects the backups only if they are stolen without the laptop,** because the restic password is on the laptop. After a theft, that password counts as burned.
- **These still slow down someone with physical access:**
  - a BIOS supervisor password;
  - Boot Order Lock;
  - the F12 boot menu turned off;
  - bottom-cover tamper detection.
- **These need nobody at boot, so they stay:**
  - swap encrypted with a fresh random key at every boot;
  - no core dumps written to disk.
- **Theft response:**
  - `docs/runbooks/laptop-stolen.md` revokes every secret in a fixed order. It's written before the first token goes on the server (Phase 1), and one revocation is practised.
  - A quarantine timer stops the tunnel, the agent and Alertmanager, and freezes deploys, once the server has been off the home network for 5 minutes (Phase 2).
- **Household data** (after Dec 13) gets its own encrypted volume and its own backups. That is a separate decision (D-5).

## Revisit

Before any household data goes on the server, as decision D-5. Its default is a separate LUKS volume unlocked by hand.
