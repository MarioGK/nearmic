# Radxa ROCK 4 Plus (v1.73 / 4B+) — Armbian 26.8.1 server setup

Board: **Radxa ROCK 4 Plus v1.73** (ROCK 4B+, RK3399, onboard eMMC)
Armbian board ID: **`rockpi-4bplus`**

Live board: **`10.10.10.39`** (Wi-Fi) / **`rockpi-4bplus.homelab.lan`** / **`rockpi-4bplus.local`**
(DHCP, VLAN 10; the address may change). Wi-Fi `wlan0` through a TP-Link Archer
T2U Nano (USB `2357:011e`); Ethernet `end0` when a cable is plugged in. Over the
USB cable: `ssh mariogk@192.168.77.1`. Live dashboard: `http://10.10.10.39/`
(port 80).

## Audio appliance: 24/7 USB microphone cleaner

This board is the deployed NearMic appliance:

```
USB microphone -> host USB port -> PipeWire -> NearMic (DeepFilterNet3 or RNNoise, + voice post)
  -> UAC2 gadget on the upper USB 3.0 Type-A OTG port
  -> host computer sees a standard USB microphone

host computer playback
  -> same UAC2 gadget (stereo speaker) -> PipeWire -> Maono interface output
  -> headphones / line out
```

The gadget is duplex: the host gets a mono microphone and a stereo speaker.
The headphone return path is a direct `pw-link` with no DSP; select the
NearMic/UAC2 playback device as the computer output to hear it on the Maono
interface.

| Item | Value |
| --- | --- |
| NearMic profile | `rock-pi-plus`, `threads=1`, `cpu_budget=0.80`. Template engine `deepfilter`; the first-boot guard switched this board to `rnnoise` with `gain_db=10` (DeepFilterNet realtime factor 0.71-0.76, limit 0.60) |
| Upper USB 3.0 Type-A | OTG0 / `fe800000.usb` — UAC2 gadget to the computer |
| Lower USB 3.0 Type-A | Host, **not for the Maono** (it failed to enumerate there, `error -71`); unused |
| USB 2.0 Type-A | Host: TP-Link Wi-Fi on one port, Maono on the other (stable) |
| USB-C | Power only (UGREEN 65 W charger verified) |
| Gadget ID | `1209:4e4d`, "NearMic USB Microphone", 48 kHz S16_LE: mono microphone + stereo speaker; also a CDC-NCM maintenance network (no serial console on the verified build) |
| Maintenance link | Board `usb0` `192.168.77.1/24` (DHCP for the host); `ssh mariogk@192.168.77.1`. Host interface: find it with `ip -br link` by MAC `02:4e:4d:00:00:02` |
| Board sink | `UAC2Gadget` playback (`playback_MONO`) |
| Board source | `UAC2Gadget` capture (`capture_FL/FR`) |
| Default sink | `UAC2Gadget` — `nearmic-default-sink` prevents WirePlumber auto-linking the processed source to Maono |
| NearMic source | `nearmic` (`capture_MONO`) |
| Headphone passthrough | `UAC2Gadget` capture FL/FR -> Maono playback FL/FR (`nearmic-headphone-link`) |
| NearMic chain | DeepFilterNet3 (template default) or RNNoise (this board), + `voice.Post` (90 Hz HPF, clarity EQ, presence-gated leveler, 5.3 ms look-ahead limiter) |
| Latency | 128-frame graph, 128-frame UAC2 periods, 1024-frame ring target — ~29-34 ms board total |
| Live audio | `out_fill` 768–1024, ~36 % of one core (~6 % of the 6-core RK3399), ~23 MB RSS |
| Errors | Passthrough removes the links and mutes the Maono output, so a broken gadget is silent instead of squealing |
| Required overlay | `/boot/overlay-user/nearmic-otg.dtbo` + `user_overlays=nearmic-otg` |
| Physical switch | **OTG/Device** slide switch on the underside, below the USB ports |

The old `dsp-dereverb` chain is still selectable, but it was the robotic one:
42.7 ms delayed-magnitude comb, oversubtraction, a three-hypothesis ensemble,
AGC pumping and a harsh presence shelf. See [QUALITY.md](QUALITY.md) for the
LocalVQE/hushmic/DPDFNet comparison, measurements and build recipe.

The stock Armbian DTB sets both dwc3 controllers to `dr_mode = "host"`, so the
overlay is mandatory and a **reboot is required** after installing it. The
overlay only switches OTG0 to peripheral/high-speed; the lower USB 3.0 port and
the USB 2.0 ports remain host ports.

Runbook and install:

- [AUDIO.md](AUDIO.md) — exact UAC2 configfs/PipeWire design, port discovery,
  systemd, udev/autosuspend, test plan, troubleshooting
- [SETUP.md](SETUP.md) — file-to-destination map and installer usage
- [../AGENTS.md](../AGENTS.md) — project/agent contract, build/deploy
  commands, 24/7 and apt policy

Key commands:

```sh
# board
ls /sys/class/udc                    # expect fe800000.usb
systemctl status nearmic-gadget
systemctl --user status nearmic nearmic-link nearmic-headphone-link
pw-link -l                           # mic: nearmic -> UAC2 playback
                                     # headphones: UAC2 capture -> Maono playback

# host computer
lsusb | grep -i 1209:4e4d
arecord -l
aplay -l
arecord -D plughw:CARD=UAC2Gadget,DEV=0 -f S16_LE -r 48000 -c 1 -d 10 /tmp/test.wav
pactl list short sinks | grep -i near   # select this as the computer output
```

## Installed image

| Item | Value |
|---|---|
| Distribution | Armbian **26.8.1** |
| Debian | **13 (trixie)**, Minimal / CLI (server, no desktop) |
| Kernel | **6.18.44** (`current`) |
| Image file | `Armbian_26.8.1_Rockpi-4bplus_trixie_current_6.18.44_minimal.img.xz` |
| Source | <https://dl.armbian.com/rockpi-4bplus/Trixie_current_minimal> |
| SHA-256 | `d702bbb6a4692f6afaebeba7360825c7f30714fb74b0373207dd2dd8a95e75a0` |
| Loader (eMMC) | `rk3399_loader_v1.30.130.bin` (`rk.sh` default; v1.27.126 cannot read past 32 MiB) |
| Loader source | <https://dl.radxa.com/rockpi4/images/loader/rk3399_loader_v1.30.130.bin> |
| Loader SHA-256 | not pinned: `rk.sh` downloads it without a check |

## Pre-configured before first boot

- User **`mariogk`** (UID 1000, `/bin/bash`, member of `sudo`)
- SSH public key installed in `/home/mariogk/.ssh/authorized_keys`
  (`ssh-ed25519 … Personal SSH`, the `id_ed25519.pub` of this workstation)
- **Passwordless sudo**: `/etc/sudoers.d/90-mariogk`
  ```
  mariogk ALL=(ALL) NOPASSWD: ALL
  ```
- SSH enabled at boot (`ssh.service`), public-key auth enabled
- Root SSH restricted to keys (`PermitRootLogin prohibit-password`)
- Armbian interactive first-login/user-creation marker removed
  (`/root/.not_logged_in_yet`)
- Wi-Fi: netplan `wlan0` generated from `rockpi4/.env` (`WIFI_SSID`, `WIFI_PASS`,
  `WIFI_COUNTRY`); Ethernet DHCP is kept as well
- mDNS: `avahi-daemon` answers as `rockpi-4bplus.local`
- First boot: `nearmic-firstboot.service` runs `apply-appliance.sh` once, then the
  engine guard (see [SETUP.md](SETUP.md))

Credentials are in `credentials.txt` (mode `0600`, git-ignored).

## Flashing to eMMC (Maskrom)

This is the supported reflash path, a last resort under
[AGENTS.md](../AGENTS.md#agent-autonomy). The field rules are in the
`rockpi-flash` skill (`.claude/skills/rockpi-flash/SKILL.md`); the image is built
with the `rockpi-image` skill.

1. Build the image on the workstation: `rockpi4/scripts/prepare-image.sh`. It
   needs `rockpi4/.env` and an aarch64 NearMic binary at `zig-out/bin/nearmic`,
   and writes `rockpi4/work/nearmic-<date>.img`. Do not partition it by hand.
2. Power off the board and remove microSD. Do **not** install the SPI jumper
   (pins 23-25). The SPI NOR is erased, so the board boots from the eMMC without
   it (see [AGENTS.md](../AGENTS.md#boot-chain)).
3. Connect a **USB-A male → USB-A male data cable** from the PC to the
   **upper USB 3.0 Type-A (OTG)** port. Power the board from its own 5 V/3 A
   USB-C supply, with nothing else on its USB ports: unplug the Wi-Fi adapter
   and the Maono while flashing. On 2026-11-11 a plain cable without tape worked
   with a UGREEN 65 W charger in that state. Do **not** use the USB-C port for
   data.
4. Start the flash. It waits for Mask ROM, then uploads the loader
   `rk3399_loader_v1.30.130.bin` (downloaded to `rockpi4/work/`), writes the
   image at LBA 0, reads it back, compares, and resets:
   ```
   rockpi4/scripts/rk.sh flash rockpi4/work/nearmic-<date>.img
   ```
5. Physical step (operator, the only one): hold the **Maskrom** button on the
   underside near the eMMC, apply power, count to 3, release.
6. If `lsusb` does not show `1209:4e4d` within 3 minutes, cold power-cycle the
   board (no button). Then run the [post-boot checks](#post-boot-checks).

Batch every change into this one flash. `rk.sh maskrom` reboots into Mask ROM
without the button while a loader is running. `rk.sh backup OUT [MB]` reads the
eMMC first if a copy is needed. `scripts/flash-emmc.sh` predates `rk.sh` and
uses loader v1.27.126, which cannot read past 32 MiB; do not use it.

## Post-boot checks

```
ssh mariogk@<board-ip>          # key is provided by the SSH agent/Bitwarden
sudo -n true && echo "passwordless sudo OK"
systemctl is-active ssh
```

Use `scripts/verify.sh <board-ip>` to run these checks automatically.
The private key is held by the SSH agent (Bitwarden); the public key in
`config/authorized_keys` is already installed on the board.

### Verified live (2026-11-11)

| Item | Value |
|---|---|
| Image | v3, flashed with `rk.sh flash`. A warm reboot with the TP-Link and Maono attached came back in about 25 s with Wi-Fi, audio routes and all units active |
| Wi-Fi | TP-Link Archer T2U Nano (`2357:011e`, RTL8811AU), `wlan0`, `10.10.10.39` (DHCP) |
| Signal | Weak at this location: about -78 to -84 dBm on 5 GHz (known limitation) |
| USB ports | TP-Link on one USB 2.0 port, Maono on the other (stable); lower USB 3.0 unused |
| USB gadget | UAC2 + CDC-NCM bound; CDC-ACM not available (`-19`) |
| Maintenance link | `192.168.77.1`, `ssh mariogk@192.168.77.1` |
| Dashboard | `http://10.10.10.39/` |
| Not tested yet | A cold power-cycle with the Wi-Fi adapter and Maono attached |

### Verified live (2026-11-09)

| Item | Value |
|---|---|
| DHCP / DNS name | `10.10.10.36` / `rockpi-4bplus.homelab.lan` (VLAN 10) |
| SSH | key login as `mariogk`, `ssh.service` active |
| sudo | `sudo -n true` → OK (NOPASSWD) |
| eMMC | `/dev/mmcblk0p1`, 28.3 GiB, root expanded, 1.5 GiB used |
| Ethernet | `end0`, 1 Gbps |

## Notes

- Armbian's netplan config is applied at boot by the
  `/usr/lib/systemd/system-generators/netplan` generator.
- The root filesystem is expanded to the eMMC size on first boot by
  `armbian-resize-filesystem.service` (uses `parted` + `fdisk` + `resize2fs`).
