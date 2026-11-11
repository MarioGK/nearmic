---
name: rockpi-image
description: Build, inspect or modify the self-provisioning NearMic Armbian image for the ROCK 4 Plus; use before flashing, when changing Wi-Fi, packages, boot config, or first-boot provisioning.
---

# Build and check the NearMic ROCK 4 Plus image

`rockpi4/scripts/prepare-image.sh` takes the pinned Armbian 26.8.1 (Debian 13
trixie) minimal image and writes a copy that provisions itself on first boot.
Flash it with the `rockpi-flash` skill.

## Inputs (workstation)

1. `rockpi4/.env` (git-ignored): keys `WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY`
   (country defaults to `BR`). Never print or `cat` it. To check the keys
   without values: `cut -d= -f1 rockpi4/.env`.
2. `zig-out/bin/nearmic`: must be an aarch64 glibc build (`file` must say
   aarch64). Build it per AGENTS.md:
   ```sh
   scripts/build-rnnoise-aarch64.sh
   zig build -Dtarget=aarch64-linux-gnu -Dcpu=cortex_a53 -Doptimize=ReleaseFast -Dbundle=true
   ```
3. `rockpi4/work/guard-clip.wav`: optional. Installed to `/opt/nearmic/bin/`
   only if present; the first-boot DeepFilterNet timing check needs it.
4. The Armbian base image: downloaded to `rockpi4/work/` if missing, and its
   SHA256 is checked against `EXPECTED_SHA` in the script.
5. Tools: `sudo`, `curl`, `xz`, `qemu-user-static` (aarch64 binfmt), `sfdisk`,
   `e2fsprogs`, `rsync`, plus `python3` and `file`, which the script also calls
   but its header does not list. `llvm-strip` is optional.
6. `$HOME/.ssh/id_ed25519.pub` must exist; it becomes the login key.

## Build

```sh
OUT=$PWD/rockpi4/work/nearmic-<tag>.img rockpi4/scripts/prepare-image.sh
```

- `OUT` must be absolute: the script `cd`s into `rockpi4/work/` before using it.
- Takes about 12 min because packages install under qemu-user emulation.
- Needs `sudo` for the whole run (loop mount, chroot). Run it where sudo can
  prompt, not in a non-interactive agent shell.
- Needs free disk in `rockpi4/work/` for the unpacked base image plus `GROW`.
  The script default is `GROW=4G`; see the gotchas.
- Overwrites `OUT` without asking. Use a new `<tag>` for each build.
- Env switches: `UPGRADE=0` skips the in-image full-upgrade (faster iteration).
  `FULL_FIRMWARE=0` keeps `armbian-firmware` instead of the full package.
  `GROW`, `MIC_SOURCE`, `TARGET_USER`, `TARGET_KEY` override the defaults.
- It writes `rockpi4/credentials.txt` (git-ignored, mode 600) with the
  generated passwords. Do not print it.

Then flash: `rockpi4/scripts/rk.sh flash <img>` (see `rockpi-flash`).

## What the image contains

- **User:** `mariogk` in `sudo,audio`, SSH key in `authorized_keys`, passwordless
  sudo (`/etc/sudoers.d/90-mariogk`). sshd: root by key only, password login on.
- **Wi-Fi:** `/etc/netplan/20-nearmic-wifi.yaml` (mode 600, networkd,
  `wlan0`, optional, DHCP). `10-nearmic-usb-wifi.link` renames any USB
  `wlan*` to `wlan0`. `cfg80211 ieee80211_regdom` set from `WIFI_COUNTRY`.
- **Wi-Fi firmware and modeswitch:** `armbian-firmware-full` replaces
  `armbian-firmware` (every Wi-Fi blob Armbian ships). The TP-Link Archer T2U
  Nano (RTL8811AU) uses the in-kernel `rtw88_8821au` driver. `usb-modeswitch`
  covers adapters that start as a driver CD.
- **Audio and names:** pipewire, wireplumber, alsa-utils; avahi + libnss-mdns
  so `rockpi-4bplus.local` resolves.
- **Boot:** `/boot/overlay-user/nearmic-otg.dtbo`, `user_overlays=nearmic-otg`,
  `extraargs=fsck.repair=yes panic=10`, and the U-Boot boot-order patch
  (`boot_targets=mmc1 mmc0 nvme0 usb0 ...`). `/etc/localtime` is copied from the
  workstation timezone (`America/Sao_Paulo` on the 2026-11-11 build), so the
  04:00 maintenance reboot is local time.
- **Gadget and maintenance link:** `nearmic-gadget.service` (UAC2 + NCM; CDC-ACM
  is tried first and dropped on the verified build, so there is no serial
  console), `30-nearmic-usb0.network` (board `192.168.77.1`, DHCP server),
  `nearmic-cpufreq.service`.
- **Wi-Fi watchdog:** `nearmic-wifi-watchdog.timer`, every 60 s from 90 s after
  boot. Never reboots. Escalates at 2 min (restart wpa), 5 min (netplan apply),
  10 min (replug the USB adapter).
- **First boot:** `nearmic-firstboot.service` runs
  `apply-appliance.sh --apply --skip-packages` (log `/var/log/nearmic-firstboot.log`),
  then `nearmic-engine-guard.sh`, restarts the user `nearmic` unit, and writes
  `/var/lib/nearmic/provisioned`. Delete that file to re-run it. The same
  apply installs the dashboard, the U-Boot boot-order guard
  (`nearmic-uboot-guard`), the apt background drop-in and the Wi-Fi hotplug rule.
- **Binary and tree:** `/opt/nearmic/` (rockpi4 tree without `work/`,
  `credentials.txt`, `.env`); `/opt/nearmic/bin/nearmic`.
- **Robustness:** persistent journald (200 MB cap), armbian-ramlog off,
  `kernel.panic=10` and `panic_on_oops=1`, systemd watchdog 15 s.
- **Kernel held** during the in-image upgrade (`linux-image-*`, `linux-dtb-*`,
  `linux-u-boot-*`); unattended-upgrades moves them later.

## Inspect a built image (read-only)

```sh
IMG=rockpi4/work/nearmic-<tag>.img
head -c 16777216 "$IMG" | strings | grep boot_targets   # U-Boot env, first 16 MiB
sfdisk -d "$IMG"                                         # p1 start=32768
LOOP=$(sudo losetup -fP --show -r "$IMG")
sudo mkdir -p /mnt/nearmic-ro
sudo mount -o ro,noload "${LOOP}p1" /mnt/nearmic-ro
cat /mnt/nearmic-ro/boot/armbianEnv.txt
sudo umount /mnt/nearmic-ro && sudo losetup -d "$LOOP"
```

## Checklist before flashing

1. `/boot/armbianEnv.txt` has `user_overlays=nearmic-otg`.
2. `strings` of the first 16 MiB shows `boot_targets=mmc1 mmc0`.
3. `/etc/netplan/20-nearmic-wifi.yaml` exists with mode 600 (`stat -c %a`).
4. `nearmic-firstboot.service` and `nearmic-gadget.service` are enabled
   (symlinks under `/etc/systemd/system/multi-user.target.wants/`).
5. `/opt/nearmic/bin/nearmic` exists, is executable and is aarch64.

## Gotchas

- **Guarded edits:** `user_overlays=` and `extraargs=` are appended only when
  the line is absent (`grep -q`). If the base image already has either line,
  nothing is added. Read `armbianEnv.txt` in the image and confirm
  `user_overlays=nearmic-otg` and `fsck.repair=yes` are both present.
- **Cleanup trap:** the trap detaches only the loop it created and restores
  `/etc/resolv.conf`. A killed run leaves loop devices behind. Check
  `losetup -a` and `findmnt | grep root` before a new build; detach stale
  loops with `sudo losetup -d /dev/loopN` only after confirming nothing mounts
  them. Also check that `/usr/sbin/policy-rc.d` and
  `/etc/resolv.conf.nearmic` are gone from the image.
- **resolv.conf swap:** during the chroot the host's `resolv.conf` is moved to
  `resolv.conf.nearmic` and replaced with `10.10.10.1` and `1.1.1.1`.
- **policy-rc.d:** a `exit 101` stub stops services starting during package
  install. It is removed after the packages step and again in the trap.
- **Secrets in the image:** Wi-Fi password (netplan, mode 600) and the
  generated passwords are inside the `.img`. Do not share or publish images.
- **Pins:** a new Armbian release needs the filename, `EXPECTED_SHA` and the
  `patch_uboot` byte strings updated together.
- **GROW must be 4G or more.** `armbian-firmware-full` unpacks to 1.9 GB. With
  `GROW=2G` the install failed with "No space left on device" after
  `armbian-firmware` was already removed. The build then stops with the Wi-Fi
  firmware swapped: rebuild, do not flash that output.
- **Test first-boot changes without a boot.** A `systemd-nspawn` boot under
  qemu-user did not work. Instead, run `apply-appliance.sh --apply --skip-packages`
  in a chroot of a throwaway reflink copy of the image. It is expected to stop at
  `loginctl enable-linger`.
- **Stale image.** The image on disk goes stale whenever `rockpi4/` changes.
  Rebuild before the next flash.
