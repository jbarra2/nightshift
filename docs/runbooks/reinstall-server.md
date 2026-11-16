# Reinstall the server: Debian 13 without disk encryption

This guide wipes the ThinkPad T480s and installs a fresh, headless Debian 13 **without full-disk encryption**. It uses LVM and leaves free space for later (`docs/design/host-ops.md`). It takes about an hour, and **everything on the laptop's SSD is erased**, including the old encrypted system.

When you're done you'll have:
- a server named `nightshift`, with a 300 GB system volume and about 600 GiB of free space for later;
- Secure Boot on, and the 2023 certificate checked before the first upgrade;
- a console you can still get into if boot fails;
- SSH from Windows with a key only, with the server's identity checked;
- the BIOS locked down.

Everything else (firewall, Docker, TLP and so on) is Phase 1 in `docs/PLAN.md`.

---

## What you need

- The T480s and its charger. Keep the charger plugged in the whole time.
- An **Ethernet cable**, plugged into the T480s's **built-in RJ-45 port** and your router. No adapter is needed.
- A USB stick of 2 GB or more. It will be erased.
- Your Windows laptop, with [Rufus](https://rufus.ie) installed.
- Your password manager, ready for three new entries: the server user's password, the BIOS supervisor password, and the SSH key passphrase.

---

## 1. Download and check the installer (Windows)

1. Go to <https://www.debian.org/download> and download the Debian 13 **netinst** image for 64-bit PC (`debian-13.x.y-amd64-netinst.iso`). Save `SHA512SUMS` (linked on the same page) next to it.
2. In PowerShell, in that folder, check the hash:
   ```powershell
   $iso = @(Get-ChildItem .\debian-13.*-amd64-netinst.iso)
   if ($iso.Count -ne 1) { throw "Expected exactly one Debian ISO here, found $($iso.Count)" }
   $expected = (Select-String -Path .\SHA512SUMS -SimpleMatch $iso[0].Name).Line.Split(' ')[0]
   (Get-FileHash -LiteralPath $iso[0].FullName -Algorithm SHA512).Hash -eq $expected
   ```
   It must print `True`. If it prints `False`, download the ISO again.
   - *Optional:* also check `SHA512SUMS.sign` with Gpg4win, following Debian's ISO verification guide.
3. Write the USB stick with Rufus:
   - **Device:** your USB stick. Double-check it's the stick, not another drive.
   - **Boot selection:** the ISO. Leave the other settings at their defaults and click **Start**.
   - When Rufus asks how to write the image, choose **DD Image mode**. Debian's wiki says DD mode is required for Debian installer images; ISO mode alters the image.

---

## 2. BIOS settings, part 1 (on the T480s)

Power on and press **F1** to open ThinkPad Setup. If you miss it, press Enter at the Lenovo logo, then F1. Use the arrow keys and Enter, and press **F10** to save and exit.

| Where | Setting | Why |
|---|---|---|
| Config → Power | **Power On with AC Attach: Enabled** | After an outage, the laptop turns itself on when power returns. |
| Security → Secure Boot | **Secure Boot: On** (leave it on) | Debian boots with it, and it stops unsigned kernel modules from loading. |
| Security → Password | **Supervisor Password:** set one and store it in your password manager | Stops anyone at the keyboard from changing BIOS settings. |
| Security → Virtualization | **Intel VT-d: Enabled** | Protects against Thunderbolt and other DMA attacks. |
| Config or Security tab | **Intel AMT: Disabled**, if you see it (vPro models only) | AMT allows remote control over the wired network. |

> **Warning:** on ThinkPads, a lost supervisor password can't be reset without replacing the system board. Save it before you press F10.
>
> Set **only** a supervisor password. A power-on or hard-disk password would stop the server from booting unattended.
>
> The boot-menu locks come at the very end (step 10), because the install uses F12.

---

## 3. Install Debian

1. Plug the USB stick into the T480s. Power on and press **F12**, then pick the USB stick.
2. Choose **Install** (text) or **Graphical install**; they ask the same questions.
3. Answer the screens:

| Screen | Answer |
|---|---|
| Language / location / keyboard | English / United States / American English |
| Network | The wired adapter, if asked |
| Hostname | `nightshift` |
| Domain name | Leave blank |
| **Root password** | **Leave both fields empty.** The root account is disabled, sudo is installed, and your user gets sudo. (Step 6 keeps the emergency console usable.) |
| Full name / username / password | Your name, the username you'll SSH in with, and a strong, **unique** password (it's also your sudo password). Save it in the password manager. |
| Time zone | Pacific |

4. **Partition disks**, carefully:
   1. Choose **Guided - use entire disk and set up LVM**. Do **not** choose "encrypted LVM".
   2. Pick the **internal SSD**: about 1 TB, shown as something like `nvme0n1` or `sda`. Make sure it isn't the USB stick.
   3. Scheme: **All files in one partition**.
   4. Confirm removing the old LVM and partitions. This erases the old encrypted system.
   5. **"Amount of volume group to use for guided partitioning":** type `300 GB`.
   6. On the overview, check that **root** is about 300 GB (minus swap), not the whole disk. If it took the whole disk, go back and re-enter the amount.
   7. **Finish partitioning and write changes to disk → Yes.**
5. **Package manager:** no extra media; mirror country United States, `deb.debian.org`; leave the proxy blank.
6. **Popularity contest:** No.
7. **Software selection:**
   - **Uncheck** "Debian desktop environment" and "GNOME".
   - **Check** "SSH server" and "standard system utilities".
   - In the text installer, Space toggles an item and Tab moves to Continue.
8. When the installation is complete, remove the USB stick and let it reboot.

---

## 4. First boot: check the result (on the laptop)

Log in at the console, then run:

```bash
ip -br addr              # note the wired IP address
sudo lvs                 # root about 279 GiB (300 GB), plus swap_1
sudo vgs                 # VFree about 600+ GiB (the volume group is nightshift-vg)
df -h /boot              # about 1 GB
mokutil --sb-state       # "SecureBoot enabled"
systemctl is-active ssh  # "active"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub   # the server's SSH fingerprint
```

- **Save the SSH fingerprint in your password manager** (not in the repo). You'll compare it on Windows in step 7.
- **If `VFree` is close to 0,** the installer used the whole disk. Reinstall now, while it costs nothing.

---

## 5. Secure Boot certificate, **before any upgrade**

New Debian boot loaders will be signed only with Microsoft's 2023 certificate, because the 2011 one expired in June 2026. Check for it using the **exact** name (there are three different "UEFI CA 2023" certificates):

```bash
sudo mokutil --db | grep -F 'Microsoft UEFI CA 2023'
```

- **If it prints a line:** you're set. Go to step 6.
- **If it prints nothing:** hold the boot-loader packages now, before anything gets upgraded:
  ```bash
  sudo apt-mark hold shim-signed shim-helpers-amd64-signed
  apt-mark showhold        # should list both
  ```
  - **Why this is low risk:** today's shim is dual-signed and still boots, and Debian's shim package also checks that a new shim will boot before installing it.
  - **Why hold anyway:** the hold makes sure nothing changes the boot loader while you're away.
  - Step 9 tries to fix the certificate.

---

## 6. Keep the emergency console usable

With no root password, Debian's emergency and rescue modes normally refuse to give you a shell. If an outage ever leaves the disk needing a manual check, you'd be locked out at the keyboard. Fix it:

```bash
for u in emergency rescue; do
  sudo mkdir -p /etc/systemd/system/$u.service.d
  printf '[Service]\nEnvironment=SYSTEMD_SULOGIN_FORCE=1\n' | sudo tee /etc/systemd/system/$u.service.d/10-locked-root.conf >/dev/null
done
sudo systemctl daemon-reload
```

**Test it once:**
1. Reboot, and at the GRUB menu press **e**.
2. At the end of the line starting with `linux`, add ` systemd.unit=emergency.target`, then press **Ctrl-X**.
3. You should get a root shell.
4. Type `reboot`.

---

## 7. Connect from Windows with an SSH key

On **Windows** (PowerShell):

```powershell
# 1. A dedicated login key (doesn't touch any existing id_ed25519). Give it a passphrase.
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\nightshift_ed25519 -C "windows-to-nightshift"
```

Then add this block to `%USERPROFILE%\.ssh\config` (create the file if needed):

```
Host nightshift
    HostName <server-ip>
    User <your-user>
    IdentityFile ~/.ssh/nightshift_ed25519
    IdentitiesOnly yes
```

```powershell
# 2. Forget any old host key for that address (the reinstall changed it)
ssh-keygen -R <server-ip>

# 3. First connection: compare the fingerprint with the one from step 4 BEFORE typing "yes".
#    Then copy your public key (this is the last time you'll type the server password over SSH).
type $env:USERPROFILE\.ssh\nightshift_ed25519.pub | ssh nightshift "umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"

# 4. Log in with the key (it asks for the key's passphrase)
ssh nightshift
```

> **Don't `ssh-add` this key.** If it stays out of ssh-agent, it asks for its passphrase every time, and no other program on Windows can use it quietly. Check with `ssh-add -l`: it shouldn't be listed.

Then, **on the server**, allow key logins only, and only for you:

```bash
sudo tee /etc/ssh/sshd_config.d/10-nightshift.conf >/dev/null <<'EOF'
AllowUsers <your-user>
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sudo sshd -t && sudo systemctl reload ssh
```

**Keep that session open.** In a second PowerShell window, confirm both of these:
- `ssh nightshift` still logs you in.
- `ssh -o PubkeyAuthentication=no nightshift` is refused.

Only then close the first session.

---

## 8. Update and reserve the address

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

After the reboot:
- **Router:** add a **DHCP reservation** for the server's wired MAC address (`ip link`, the `link/ether` value), so the server keeps the same IP. Phase 1 also sets that address on the server.
- **If you installed over Wi-Fi:** remove the Wi-Fi stanza and its passphrase from `/etc/network/interfaces` once the wired connection works.

---

## 9. Firmware and the Secure Boot certificate (when you're home, on AC)

Do this whether or not step 5 found the certificate; firmware updates are worth checking once. **Always by hand**, never from a script.

```bash
sudo apt install -y fwupd
sudo fwupdmgr refresh
sudo fwupdmgr get-updates
sudo fwupdmgr security      # look at the "UEFI db" line
```

1. **Apply what's offered:** if `get-updates` lists anything (system firmware, or a Secure Boot db, KEK or dbx update), run `sudo fwupdmgr update` with the charger plugged in. It may reboot to flash; don't interrupt it.
   - LVFS may only have management-engine and embedded-controller firmware for the T480s. Lenovo's support site may have a newer BIOS.
2. **After a BIOS update,** Lenovo's process on other ThinkPads is: go to ThinkPad Setup → **Security → Secure Boot → Restore Factory Keys**, save, then boot Debian and run `sudo fwupdmgr update` again to re-apply the revocation list (dbx).
3. **Check again:**
   ```bash
   sudo mokutil --db | grep -F 'Microsoft UEFI CA 2023'
   ```
   - **Now present:** remove the hold with `sudo apt-mark unhold shim-signed shim-helpers-amd64-signed`, then `sudo apt full-upgrade`.
   - **Still missing:** keep the hold, write it in `LOG.md`, and settle decision D-10 by Dec 13.

---

## 10. BIOS settings, part 2: lock it down

Reboot into ThinkPad Setup (F1), then press F10 to save:

| Where | Setting |
|---|---|
| Startup | **Boot Order Lock: Enabled** |
| Startup | **Boot Device List F12 Option: Disabled** |
| Security | **Bottom Cover Tamper Detection: Enabled**. After the cover is opened, the next boot asks for the supervisor password. |

Without disk encryption, these are what slow down someone with a few minutes and a USB stick. Menu names may differ slightly on the T480s. To reinstall later, enter the supervisor password and undo them.

---

## 11. Done

Add a `LOG.md` entry with:
- the date;
- the root and free sizes, and `/boot`;
- the Secure Boot result, and whether the shim hold is on;
- the BIOS version (`sudo dmidecode -s bios-version`).

The repo is public: keep the server's IP and MAC addresses, the SSH fingerprint and the serial number out of the log (PLAN section 10, "Public repo hygiene").
Then continue with **Phase 1** in `docs/PLAN.md`.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| The USB stick isn't in the F12 menu | Write it again in **DD Image mode**, try another USB port, and check that ThinkPad Setup → Startup → UEFI/Legacy Boot allows UEFI. |
| "Secure Boot violation" or "verification failed" when booting the USB | The firmware doesn't trust the installer's boot loader. Turn Secure Boot off, install, do step 9, then try turning it back on. If Debian still won't boot with it on, leave it off and record it (D-10). |
| No wired network during the install | Check the cable and the router port. As a fallback the installer can use Wi-Fi (the T480s's Intel Wi-Fi firmware is on the official image); clean up afterwards (step 8). |
| "Cannot open access to console, the root account is locked" | Step 6 didn't apply. At the GRUB menu press **e**, add ` SYSTEMD_SULOGIN_FORCE=1 systemd.unit=emergency.target` to the `linux` line, press Ctrl-X, then redo step 6. |
| The fingerprint doesn't match in step 7 | Stop. Don't type `yes`. Check the IP address, and look for another device answering at that address. |
| "REMOTE HOST IDENTIFICATION HAS CHANGED" on Windows | Expected right after a reinstall: `ssh-keygen -R <server-ip>`, then compare the fingerprint again. |
| Locked out of SSH after step 7 | Log in at the laptop's console, run `sudo rm /etc/ssh/sshd_config.d/10-nightshift.conf && sudo systemctl reload ssh`, fix the key, and try again. |
| The laptop doesn't turn on by itself when power returns | Check Config → Power → Power On with AC Attach. It only fires at the moment AC appears, which is why Nightshift reboots instead of powering off when AC is already back (`docs/design/power.md`). |

## Sources

- Debian download page and ISO verification: https://www.debian.org/download
- Debian wiki, writing installer images with Rufus (DD mode): https://wiki.debian.org/DebianInstall
- Debian installation guide, root password and sudo: https://www.debian.org/releases/trixie/amd64/apas03.en.html
- Debian installer guided LVM size prompt: https://lists.debian.org/debian-boot/2018/07/msg00131.html
- Debian lists, locked root and `SYSTEMD_SULOGIN_FORCE`: https://lists.debian.org/debian-doc/2024/12/msg00025.html
- Debian shim-signed changelog (dual-signed shim, boot check): https://metadata.ftp-master.debian.org/changelogs/main/s/shim-signed/stable_changelog
- Microsoft KB5062710, Secure Boot certificates: https://support.microsoft.com/kb/5062710
- Trixie release notes, `/boot` size: https://www.debian.org/releases/trixie/release-notes/issues
- Lenovo PSREF, ThinkPad T480s (built-in RJ-45): https://psref.lenovo.com/syspool/Sys/PDF/ThinkPad/ThinkPad_T480s/ThinkPad_T480s_Spec.PDF
- Lenovo, Secure Boot and Restore Factory Keys: https://support.lenovo.com/solutions/HT509044
- ThinkPad "Power On with AC Attach" (T470 user guide, same BIOS family): https://www.manualslib.com/manual/2715242/Thinkpad-T470.html?page=91
