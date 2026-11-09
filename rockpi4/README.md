# Radxa ROCK 4 Plus (v1.73 / 4B+) — Armbian 26.8.1 server setup

Board: **Radxa ROCK 4 Plus v1.73** (ROCK 4B+, RK3399, onboard eMMC)
Armbian board ID: **`rockpi-4bplus`**

Live board: **`10.10.10.36`** / **`rockpi-4bplus.homelab.lan`** (DHCP, VLAN 10),
Ethernet `end0`.

## Audio appliance: 24/7 USB microphone cleaner

This board is the deployed NearMic appliance:

```
USB microphone -> host USB port -> PipeWire -> NearMic (RNNoise + voice post)
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
| NearMic profile | `rock-pi-plus`, `threads=1`, `cpu_budget=0.80`, engine `rnnoise`, `gain_db=10` |
| Upper USB 3.0 Type-A | OTG0 / `fe800000.usb` — UAC2 gadget to the computer |
| Lower USB 3.0 Type-A | Host — USB microphone |
| USB 2.0 Type-A | Host — USB microphone |
| USB-C | Power only |
| Gadget ID | `1209:4e4d`, "NearMic USB Microphone", 48 kHz S16_LE: mono microphone + stereo speaker |
| Board sink | `UAC2Gadget` playback (`playback_MONO`) |
| Board source | `UAC2Gadget` capture (`capture_FL/FR`) |
| Default sink | `UAC2Gadget` — `nearmic-default-sink` prevents WirePlumber auto-linking the processed source to Maono |
| NearMic source | `nearmic` (`capture_MONO`) |
| Headphone passthrough | `UAC2Gadget` capture FL/FR -> Maono playback FL/FR (`nearmic-headphone-link`) |
| NearMic chain | RNNoise + `voice.Post` (90 Hz HPF, clarity EQ, presence-gated leveler, 5.3 ms look-ahead limiter) |
| Latency | 128-frame graph, 128-frame UAC2 periods, 1024-frame ring target — ~29-34 ms board total |
| Live audio | `out_fill` 768–1024, ~36 % of one core (~6 % of the 6-core RK3399), ~23 MB RSS |
| Errors | Passthrough removes the links and mutes the Maono output, so a broken gadget is silent instead of squealing |

The old `dsp-dereverb` chain is still selectable, but it was the robotic one:
42.7 ms delayed-magnitude comb, oversubtraction, a three-hypothesis ensemble,
AGC pumping and a harsh presence shelf. See [QUALITY.md](QUALITY.md) for the
LocalVQE/hushmic/DPDFNet comparison, measurements and build recipe.
| Required overlay | `/boot/overlay-user/nearmic-otg.dtbo` + `user_overlays=nearmic-otg` |
| Physical switch | **OTG/Device** slide switch on the underside, below the USB ports |

The stock Armbian DTB sets both dwc3 controllers to `dr_mode = "host"`, so the
overlay is mandatory and a **reboot is required** after installing it. The
overlay only switches OTG0 to peripheral/high-speed; the lower USB 3.0 port and
the USB 2.0 ports remain host ports.

Runbook and install:

- [AUDIO.md](AUDIO.md) — exact UAC2 configfs/PipeWire design, port discovery,
  systemd, udev/autosuspend, test plan, troubleshooting
- [SETUP.md](SETUP.md) — file-to-destination map and installer usage
- [../AGENTS.md](../AGENTS.md) — project/agent contract, safety rules,
  build/deploy commands, 24/7 and apt policy

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
| Loader (eMMC) | `rk3399_loader_v1.27.126.bin` |
| Loader source | <https://dl.radxa.com/rockpi4/images/loader/rk3399_loader_v1.27.126.bin> |
| Loader SHA-256 | `f2a7ba944edaa77821984bcc510e35c4c758b56b7f75ddf0dba3f9ebfbaf1f5a` |

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

Credentials are in `credentials.txt` (mode `0600`, git-ignored).

## Flashing to eMMC (Maskrom)

1. Power off the board, remove microSD.
2. If the board has a populated SPI flash (v1.73 made before 2022-08-05),
   jumper **pin 23 (SPI1_CLK) to pin 25 (GND)** on the 40-pin header.
3. Connect a **USB-A male → USB-A male data cable** from the PC to the
   **upper USB 3.0 Type-A (OTG)** port. Do **not** use the USB-C port for data.
4. Hold the **Maskrom** button, apply power (5 V/3 A USB-C supply), release
   after power-up. Verify:
   ```
   lsusb -d 2207:
   # 2207:330c ... RK3399 in Mask ROM mode
   sudo rkdeveloptool ld
   # DevNo=1 Vid=0x2207,Pid=0x330c ... Maskrom
   ```
5. Remove the SPI jumper now (docs: remove after entering Maskrom).
6. Flash:
   ```
   sudo rkdeveloptool db rk3399_loader_v1.27.126.bin
   sleep 5
   sudo rkdeveloptool cs 1          # select eMMC explicitly
   sudo rkdeveloptool rci           # must return chip info, not hang
   sudo rkdeveloptool wl 0 Armbian_26.8.1_Rockpi-4bplus_trixie_current_6.18.44_minimal.img
   sudo rkdeveloptool rd
   ```

   If `rci` hangs or `wl` stalls, the Maskrom USB session is wedged:
   cold power-cycle the board, re-enter Maskrom, and retry once. A different
   USB-A to USB-A cable or a rear motherboard USB port may also be required.
   Or use `scripts/flash-emmc.sh`.
7. First boot takes 1–3 minutes (filesystem resize + SSH host keys).

## Post-boot checks

```
ssh mariogk@<board-ip>          # key is provided by the SSH agent/Bitwarden
sudo -n true && echo "passwordless sudo OK"
systemctl is-active ssh
```

Use `scripts/verify.sh <board-ip>` to run these checks automatically.
The private key is held by the SSH agent (Bitwarden); the public key in
`config/authorized_keys` is already installed on the board.

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
