# AGENTS.md — NearMic ROCK 4 Plus USB microphone appliance

This file is the contract for an agent working in this repository and for the
operator maintaining the board. Read it before changing deploy files, the
board's audio graph, or its systemd units.

## Agent autonomy

The operator grants a standing, per-request-free mandate to operate this
appliance end to end. An agent working here does not need to ask before:

- editing anything in this repo, including `rockpi4/`, the docs and this file,
  and committing the result;
- deploying to `10.10.10.39` — `scp`/`rsync` the binary and deploy tree,
  running `apply-appliance.sh` (dry run or `--apply`), and installing the
  `unattended-upgrades`/`needrestart` policy;
- restarting `nearmic`, `nearmic-link`, `nearmic-headphone-link`,
  `nearmic-gadget`, or **PipeWire and WirePlumber**, and running
  `wpctl`/`pw-link`/`systemctl` commands on the board;
- **rebooting the board** or power-cycling it whenever a deploy, overlay,
  kernel, watchdog or firmware change needs it, including outside the 04:00
  window. Reboot, wait for it to come back, and verify the audio path
  yourself;
- running package operations **on the board** (`apt`, `dpkg`, `systemd-analyze`,
  firmware tooling) when a deploy or diagnosis needs them;
- installing, reloading or removing systemd units, udev rules, WirePlumber
  fragments and kernel overlays on the board;
- pushing the repo to its remote when the change is complete and verified.

After any change, self-verify with the [verification commands](#verification-commands)
and the health timer, fix what is broken, and only then report back. Prefer to
act and confirm the result over asking a question that a verification command
would answer.

Two limits remain, because they are destructive or out of scope rather than
operational: never write secrets, private keys or tokens into a tracked file,
and never change the HomeLab router.

Reflashing the eMMC is allowed as a last resort: when the board cannot be
repaired over the network or the USB maintenance link. The operator authorized
it on 2026-11-10 and 2026-11-11. Flash only an image built by
`rockpi4/scripts/prepare-image.sh`, written with `rockpi4/scripts/rk.sh flash`.
It needs one physical Mask ROM button press from the operator, so batch every
change into a single flash. Never repartition the eMMC by hand. Procedure:
[rockpi4/README.md](rockpi4/README.md#flashing-to-emmc-maskrom) and the
`rockpi-flash` skill in `.claude/skills/`.

## Goal

Turn a Radxa ROCK 4 Plus v1.73 into a 24/7 **USB microphone cleaner**:

```
USB microphone
  -> ROCK 4 Plus host USB port
  -> PipeWire
  -> NearMic (Zig, DeepFilterNet3 or RNNoise + voice post, rock-pi-plus profile)
  -> UAC2 USB gadget on the upper USB 3.0 Type-A OTG port
  -> host computer sees a USB microphone
```

The same UAC2 gadget is duplex: the host also sees a **stereo speaker**.
Host playback goes over USB-OUT to the board's `UAC2Gadget` capture PCM and is
passed straight to the Maono interface's playback outputs (headphones), with no
DSP and no extra loopback node.

```
host computer playback
  -> UAC2 gadget capture (board ALSA UAC2Gadget, stereo S16_LE 48 kHz)
  -> pw-link capture_FL/FR
  -> Maono playback sink playback_FL/FR
  -> headphones / line out on the audio interface
```

The host computer must not need a NearMic install. It sees a standard
USB Audio Class 2 device (`1209:4e4d`, product string "NearMic") with one mono
microphone and one stereo playback device. A PipeWire desktop lists them as
"NearMic Mono" (input) and "NearMic Analog Stereo" (output).

## Board and network

| Item | Value |
| --- | --- |
| Board | Radxa ROCK 4 Plus v1.73 (ROCK 4B+/4A+ PCB), RK3399 |
| SoC | Rockchip OP1 / RK3399, 2x Cortex-A72 + 4x Cortex-A53, no NPU |
| OS | Armbian 26.8.1, Debian 13 Trixie Minimal, kernel 6.18.44 |
| Storage | 32 GB eMMC, root on `/dev/mmcblk0p1` |
| Address | `10.10.10.39` on Wi-Fi (DHCP, VLAN 10; may change) |
| DNS | `rockpi-4bplus.homelab.lan`, mDNS `rockpi-4bplus.local` |
| USB maintenance link | `192.168.77.1` (CDC-NCM, see [Maintenance access](#maintenance-access)) |
| Network | Wi-Fi `wlan0` (USB adapter, netplan + networkd + wpa_supplicant); Ethernet `end0`, 1 Gbps, when a cable is plugged in |
| Wi-Fi adapter | TP-Link Archer T2U Nano, USB `2357:011e`, RTL8811AU. In-kernel driver `rtw88_8821au`; firmware from `armbian-firmware-full`. Known limitation: signal at the board's location is weak (about -78 to -84 dBm on 5 GHz) |
| Login | `mariogk`, SSH key, passwordless sudo |
| Audio | PipeWire + WirePlumber as the `mariogk` user, 48 kHz |

The board has had no Ethernet cable since 2026-11-10 and joins Wi-Fi through a
USB adapter. `rockpi4/network/10-nearmic-usb-wifi.link` names the adapter
`wlan0`, and netplan configures it at image build time from `rockpi4/.env`
(variables `WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY`; the file is git-ignored).
Ethernet DHCP still works when a cable is plugged in. Command examples use
`10.10.10.39`; substitute `rockpi-4bplus.local` or `192.168.77.1` (USB link)
when that address differs. See [rockpi4/README.md](rockpi4/README.md).

**Never write credentials, SSH private keys, tokens, or router passwords into
a tracked file.** `rockpi4/credentials.txt` is local and git-ignored. Keep any
generated credentials out of git.

## Maintenance access

When the gadget is up, the same A-to-A cable carries a composite USB device.
Its audio part is unchanged: the host still sees `1209:4e4d` with one mono
microphone and one stereo playback device. One maintenance function is bound:

- **CDC-NCM network (verified 2026-11-11).** Board `usb0` is `192.168.77.1/24`
  with a DHCP server for the host (`rockpi4/network/30-nearmic-usb0.network`).
  The host gets a 192.168.77.x address by DHCP. Its interface name depends on
  the host port: find it with `ip -br link` by MAC `02:4e:4d:00:00:02`. Then
  `ssh mariogk@192.168.77.1`.
- **No serial console.** The controller cannot bind audio + CDC-NCM + CDC-ACM
  together: `udc fe800000.usb: failed to start nearmic: -19`. The serial
  function is therefore off by default (`NEARMIC_ACM=0`), so no
  `/dev/ttyACM*` appears. `NEARMIC_ACM=1` tries it first and falls back to
  audio + NCM, then audio only, if the bind fails.

The fallback order is audio + serial + network, then audio + network, then
audio only. A maintenance function the kernel cannot bind never blocks the
microphone. `usb0` exists only when the network function binds.

## Dashboard

The NearMic Console is a live page on port 80 of the board: CPU, memory,
temperatures, network, units, USB devices, the NearMic status and a Maono input
level meter. Open `http://10.10.10.39/` on Wi-Fi, or `http://192.168.77.1/` over
the USB link.

- Source: `rockpi4/dash/nearmic-dash.py` and `index.html`, installed to
  `/usr/local/share/nearmic/dash/`. Standard library only.
- Unit: `rockpi4/systemd/nearmic-dash.service`. Runs as `mariogk` with
  `CAP_NET_BIND_SERVICE`, pinned to the A53 cores (`CPUAffinity=0-3`), `Nice=10`,
  `MemoryMax=96M`, `Restart=always`.
- Endpoints: `/` (the page), `/api` (JSON snapshot), `/levels` (input meter).
- Sampling is idle by default. It samples only while a client asked for data in
  the last 15 s, and the Maono meter (a `pw-record` tap) runs only then.

## Hardware topology and USB port map

| Physical port | Controller / DT node | Role |
| --- | --- | --- |
| Upper USB 3.0 Type-A | OTG0, `usbdrd3_0`, `/usb@fe800000/usb@fe800000` | **Peripheral/gadget** to the host computer |
| Lower USB 3.0 Type-A | OTG1, `usbdrd3_1`, `/usb@fe900000/usb@fe900000` | Host, **not used for the Maono**: it failed to enumerate there (`error -71`, "unable to enumerate USB device", in a loop). Unused in the verified layout |
| USB 2.0 Type-A ports | `usb_host0_*` / `usb_host1_*` (`fe380000`, `fe3c0000`) | Host. Verified layout: TP-Link Wi-Fi on one port, Maono on the other (stable) |
| USB-C | Power only | 5 V/3 A supply (verified with a UGREEN 65 W USB-C charger); not a data port |

The upper port is the Maskrom/OTG port. Use a **USB-A male to USB-A male data
cable** from that port to the host computer. Use a normal USB cable for the
microphone on a host port. Do not try to put both the microphone and the host
on the upper port: it is a device port after the overlay.

**Physical OTG switch:** ROCK 4A/4B boards have a small slide switch on the
**underside, below the USB ports**. It must be set to **OTG/Device**, not Host.
If it is on Host, the upper USB 3.0 port never enumerates as a device even
with the overlay loaded. Check this switch before debugging software.

The stock Armbian DTB sets **both** dwc3 controllers to `dr_mode = "host"`, so
`/sys/class/udc` is empty until the NearMic overlay is active:

- `rockpi4/dtb/nearmic-otg.dts` — source
- `rockpi4/dtb/nearmic-otg.dtbo` — compiled overlay
- Install to `/boot/overlay-user/nearmic-otg.dtbo`
- Add `user_overlays=nearmic-otg` to `/boot/armbianEnv.txt`
- The overlay sets `dr_mode = "peripheral"` and
  `maximum-speed = "high-speed"` on OTG0
- **Reboot is required** before `/sys/class/udc/fe800000.usb` exists

The overlay only changes OTG0 to peripheral. The lower USB 3.0 port and the
USB 2.0 ports remain host ports.

### Boot chain

The board hung before Linux on many power-ups and resets on 2026-11-10/11
(green LED on, blue heartbeat never starting, nothing on USB). Two changes to
the boot chain are in place; the first is the one that fixed it.

1. **Rockchip DDR blob as the first stage (the fix).** Armbian's stock
   `idbloader.img` for this board uses U-Boot's open-source TPL for memory
   init. With it, identical software booted at 09:33 and then failed
   repeatedly from 11:03, with and without USB devices attached, from cold
   power-on and from a Mask ROM reset. The eMMC was read back in Mask ROM:
   bootloader area and boot files were intact, and the filesystem had not been
   mounted since 09:33. Replacing only that stage with
   `rk3399_ddr_800MHz_v1.30.bin` (`mkimage -n rk3399 -T rksd -d
   <blob>:u-boot-spl.bin`, Armbian's "tpl-blob" layout, same SPL and U-Boot)
   gave: boot 24 s after the write, then 10 of 10 `systemctl reboot` and 5 of 5
   forced resets (`sysrq b`/`c`), all with the TP-Link and the Maono plugged
   in. `prepare-image.sh` builds this idbloader into the image and keeps a
   copy in `/usr/local/share/nearmic/boot/`. The mechanism (marginal DDR
   training on this v1.73 board) is inferred from that A/B result, not
   observed on a serial console. **A cold power-cycle test is still pending.**
2. **eMMC before USB.** Armbian's U-Boot 2022.07 default is
   `boot_targets=usb0 mmc1 mmc0 nvme0 ...`. `prepare-image.sh` patches the
   default environment inside `u-boot.itb` to `mmc1 mmc0 nvme0 usb0 ...` (same
   length), and `nearmic-uboot-guard` re-applies it to the eMMC boot area and
   to `/usr/lib/linux-u-boot-*/u-boot.itb` at boot and after every dpkg run.
   This alone did not stop the hangs.

Do not replace the bootloader with a self-built mainline U-Boot without a
serial console: a 2025.10 build written on 2026-11-11 was not accepted by the
boot ROM (the board dropped to Mask ROM) and had to be replaced over USB.
A backup of the stock Armbian boot area is in
`rockpi4/work/bootarea-armbian-2022.07.bin` and on the board in
`/var/lib/nearmic/`.

The SPI NOR flash is erased, so no SPI jumper is needed for Mask ROM or normal
boot. Do not install the pin 23-25 jumper in normal operation.
(`rockpi4/scripts/erase-spi.sh` is the erase procedure.)

## Repo layout

| Path | Purpose |
| --- | --- |
| `src/` | Zig source; **do not change for appliance work** |
| `build.zig` | Build definition; **do not change for appliance work** |
| `rockpi4/` | Board image, deployment, appliance config |
| `rockpi4/AUDIO.md` | Detailed gadget/PipeWire design and runbook |
| `rockpi4/SETUP.md` | File-to-destination map and install steps |
| `rockpi4/dtb/` | NearMic OTG overlay |
| `rockpi4/scripts/setup-uac2-gadget.sh` | configfs duplex UAC2 gadget setup/stop; CDC-NCM maintenance network (CDC-ACM is tried first and dropped on the verified build) |
| `rockpi4/scripts/prepare-image.sh` | Workstation: builds the self-provisioning eMMC image into `rockpi4/work/` |
| `rockpi4/scripts/rk.sh` | Workstation: Mask ROM `wait`/`flash`/`backup`/`stress` over `rkdeveloptool` |
| `rockpi4/.env` | Wi-Fi variables (`WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY`) read by `prepare-image.sh`; git-ignored |
| `rockpi4/scripts/nearmic-engine-guard.sh` | First-boot check: keeps DeepFilterNet only if it runs in realtime, else RNNoise |
| `rockpi4/scripts/nearmic-wifi-watchdog.sh` | Repairs the Wi-Fi link every 60 s; never reboots the board |
| `rockpi4/systemd/nearmic-wifi-watchdog.{service,timer}` | Timer and oneshot for the Wi-Fi watchdog |
| `rockpi4/systemd/nearmic-firstboot.service` | Runs `apply-appliance.sh` once on first boot, no network needed |
| `rockpi4/systemd/nearmic-cpufreq.service` | A72 cluster frequency policy |
| `rockpi4/network/`, `rockpi4/udev/` | Wi-Fi link name (`wlan0`), USB maintenance link addressing, Wi-Fi power save off; `70-nearmic-wifi.rules` starts `netplan-wpa-wlan0` when `wlan0` appears |
| `rockpi4/dash/` | NearMic Console: `nearmic-dash.py` (stdlib HTTP server on port 80) and `index.html`; see [Dashboard](#dashboard) |
| `rockpi4/systemd/nearmic-dash.service` | Dashboard unit: user `mariogk`, A53 cores, `Nice=10`, 96 MB cap |
| `rockpi4/scripts/nearmic-uboot-guard.py` | Re-applies the eMMC-first U-Boot boot order at boot and after every dpkg run |
| `rockpi4/systemd/nearmic-uboot-guard.service`, `rockpi4/apt/99nearmic-uboot-guard` | Boot unit and apt `DPkg::Post-Invoke` hook for the guard |
| `rockpi4/systemd/apt-background.conf` | Drop-in for apt-daily, apt-daily-upgrade and unattended-upgrades: A53 cores, idle priority |
| `rockpi4/config/99-nearmic-sysctl.conf` | Kernel panic and oops reboot after 10 s |
| `rockpi4/scripts/nearmic-link.sh` | PipeWire source-to-gadget-sink supervisor; sets the gadget default sink and prunes foreign source links |
| `rockpi4/scripts/nearmic-default-sink.sh` | `ExecStartPre` helper: UAC2 gadget default sink and 128-frame graph quantum |
| `rockpi4/QUALITY.md` | RNNoise/LocalVQE/DPDFNet analysis, old robotic-chain root cause, measurements, build |
| `rockpi4/scripts/nearmic-headphone-link.sh` | UAC2 capture-to-Maono playback passthrough supervisor; mutes the Maono output when the route breaks (no squeal) |
| `rockpi4/scripts/nearmic-health.sh` | One-shot 24/7 self check: gadget, units, streaming, default sink, routes, quantum |
| `rockpi4/systemd/nearmic-health.{service,timer}` | User timer that runs the health check every 60 s |
| `rockpi4/wireplumber/51-nearmic-latency.conf` | No suspend-on-idle and 128-frame ALSA periods for the UAC2 gadget |
| `rockpi4/host/` | Optional host-computer keepalive that holds the microphone open |
| `rockpi4/scripts/apply-appliance.sh` | Idempotent appliance installer |
| `rockpi4/systemd/` | Gadget, NearMic and link units, limits drop-in |
| `rockpi4/apt/` | Unattended upgrades and needrestart policy |
| `rockpi4/config/` | NearMic config template and PAM limits |
| `rockpi4/work/` | Local image artifacts, git-ignored |

## Build

Use Zig 0.14.1. The appliance **must** use the glibc aarch64 build. The static
musl binary cannot `dlopen` Debian's glibc PipeWire (verified:
`Dynamic loading not supported`). Stage RNNoise, then build:

```sh
scripts/build-rnnoise-aarch64.sh
zig build -Dtarget=aarch64-linux-gnu -Dcpu=cortex_a53 -Doptimize=ReleaseFast -Dbundle=true
```

`-Dcpu=cortex_a53` is the ISA common to both RK3399 clusters and has NEON.
Do not build with `-Dcpu=native` on the x86 workstation. The musl target stays
useful for offline DSP/fixtures only; it cannot run the live PipeWire path.
See [rockpi4/QUALITY.md](rockpi4/QUALITY.md) for the model comparison.

Tests:

```sh
zig build test -Dbundle=true
```

## Deploy

The binary must be at `~/.local/bin/nearmic`. The appliance installer preserves
an existing `~/.config/nearmic/config.toml`; set `source` there to the real USB
microphone's PipeWire `node.name`.

```sh
# from the workstation
ssh mariogk@10.10.10.39 'mkdir -p ~/.local/bin'
scp zig-out/bin/nearmic mariogk@10.10.10.39:~/.local/bin/nearmic
ssh mariogk@10.10.10.39 'chmod 0755 ~/.local/bin/nearmic'

# copy only the deploy tree (work/ is large and git-ignored)
rsync -a --exclude work --exclude credentials.txt \
  rockpi4/ mariogk@10.10.10.39:/tmp/nearmic-rockpi4/

# dry run first, then apply; --reboot reboots in the same step
ssh mariogk@10.10.10.39 \
  'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh'
ssh mariogk@10.10.10.39 \
  'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply --reboot'
```

If the overlay was just installed, reboot the board when the deploy needs it —
no coordination round trip required — then verify `/sys/class/udc/fe800000.usb`
and the gadget unit after it comes back. The gadget service will fail with a
clear message until `/sys/class/udc/fe800000.usb` exists.

Do not run `nearmic setup` after `apply-appliance.sh`: it rewrites
`~/.config/systemd/user/nearmic.service` from `src/install.zig` and drops the
appliance restart/priority limits. Re-run the installer or edit the installed
unit.

## NearMic profile

`~/.config/nearmic/config.toml` on the board (template values; the engine notes
below say what this board runs):

```toml
profile = "rock-pi-plus"
engine = "deepfilter"
mode = "suppress"
listen = false
gain_db = 0
source = ""          # set to the USB mic's PipeWire node.name
threads = 1
cpu_budget = 0.80
```

- `profile = "rock-pi-plus"` sets the RK3399 budget. RNNoise is single-threaded,
  so the appliance pins `threads = 1` and `cpu_budget = 0.80`; the user allows
  up to 80 % CPU. DeepFilterNet3 runs on the two A72 cores; the engine guard
  times it on cores 4 and 5.
- `engine = "deepfilter"` is the template default: DeepFilterNet3, full-band
  48 kHz, embedded in the binary. `nearmic-engine-guard.sh` runs once from
  `nearmic-firstboot.service`, times a 10 s clip on cores 4-5, and keeps
  DeepFilterNet only if its realtime factor is 0.60 or less. Otherwise it sets
  `engine = "rnnoise"` and `gain_db = 10`. RNNoise is the fallback: about 20 ms
  less delay, more residual noise, and robotic on far speech. `voice.Post` adds a 90 Hz high-pass, -2 dB low
  shelf, +4 dB presence peak, +2 dB air shelf, a presence-gated speech
  leveler and a 5.3 ms look-ahead limiter. The legacy
  `dsp`/`dsp-dereverb` engines remain selectable but are not the default. See
  [rockpi4/QUALITY.md](rockpi4/QUALITY.md).
- This board runs `engine = "deepfilter"`, `gain_db = 0` (since 2026-11-11).
  Measured live with a speech clip: 5.4 ms per 10 ms frame, about 68 % of one
  A72 core while speech is present (about 2 % in silence), 0 underruns. On the
  same clip its pauses sit at -45 dBFS against -37 dBFS for RNNoise. The guard
  limit is 0.85 because its 10 s clip run includes about 1.3 s of model
  start-up (0.69-0.73 here); the earlier 0.60 limit wrongly fell back to
  RNNoise. `~/.config/nearmic/config.toml.rnnoise.bak` is the previous config.
- `gain_db = 0` is the template value for DeepFilterNet, which keeps the speech
  level. `gain_db = 10` is the RNNoise makeup gain, set by the guard on fallback.
  `voice.Post` then runs a speech
  leveler (4:1 above -24 dBFS, up to +12 dB of presence-gated lift below it,
  per-sample gain ramping, +6 dB trim) and a look-ahead limiter at -2 dBFS.
  The limiter's 256-sample look-ahead is why the chain can be loud without
  the flat-topped "popping" of a reactive limiter. Do not raise `gain_db` to
  get far-field level; the leveler normalises it.
- `source` is the PipeWire `node.name` of the real microphone. Leaving it
  empty is racy on a headless boot; discover and set it explicitly.
- `mode = "suppress"`, `listen = false`. Do not enable `listen` on the
  appliance; it would feed the processed voice back into the room.
- An explicit `threads`/`cpu_budget` line overrides the profile. Do not set
  them unless you are deliberately changing the budget.

NearMic publishes a PipeWire source with:

- `node.name = "nearmic"`
- `node.description = "NearMic"`
- mono, 48 kHz, F32
- capture helper node `nearmic-capture`
- optional listen node `nearmic-listen` (disabled)

The UAC2 gadget is **duplex** on the board: a mono playback sink
(`UAC2Gadget`, S16_LE 48 kHz, `playback_MONO`) for the microphone and a stereo
capture source (`UAC2Gadget`, S16_LE 48 kHz, `capture_FL/FR`) for host playback.
The kernel f_uac2 direction is easy to invert:

| Configfs attribute | Value | Kernel path | Meaning |
| --- | --- | --- | --- |
| `p_chmask` | `1` | `ALSA_Playback -> USB-IN` | Host records this as its microphone |
| `p_srate` | `48000` | | Host capture rate |
| `p_ssize` | `2` | | S16_LE |
| `c_chmask` | `3` | `USB-OUT -> ALSA_Capture` | Host plays to this as a stereo speaker |
| `c_srate` | `48000` | | Host playback rate |
| `c_ssize` | `2` | | S16_LE |

`nearmic-link.sh` links the NearMic source's output port to the gadget's
`playback_MONO`. `nearmic-headphone-link.sh` links the gadget's capture
`capture_FL/FR` to the Maono playback sink `playback_FL/FR`. Both scripts
enumerate `pw-link -o`/`-i` and do not hardcode platform-derived node names.
`nearmic-link.sh` never links monitors or capture ports back into NearMic;
`nearmic-headphone-link.sh` never links the Maono capture ports or the NearMic
source into the Maono sink, so there is no feedback loop. Do not use
`pw-loopback` for these fixed routes; `pw-link` keeps one explicit link and no
extra node.

## Audio graph

```
USB mic (host port)
  -> PipeWire source: alsa_input.usb-...
  -> nearmic-capture (PipeWire stream, mono F32 48 kHz)
  -> NearMic worker: DeepFilterNet3 (or RNNoise, 480-sample frame) + voice post
  -> NearMic source: node.name "nearmic", capture_MONO, mono F32 48 kHz
  -> nearmic-link (pw-link nearmic:capture_MONO <sink>:playback_MONO)
  -> UAC2 gadget sink: UAC2Gadget, playback_MONO, mono S16_LE 48 kHz
  -> dwc3 OTG0 (fe800000.usb), peripheral mode
  -> host computer: USB microphone
```

The reverse direction is a separate, DSP-free path:

```
host computer playback
  -> UAC2 gadget capture: UAC2Gadget, capture_FL/FR, stereo S16_LE 48 kHz
  -> dwc3 OTG0 (fe800000.usb), peripheral mode
  -> nearmic-headphone-link (pw-link <source>:capture_FL/FR <maono>:playback_FL/FR)
  -> Maono playback sink: alsa_output.usb-Maono_...analog-stereo
  -> audio interface headphones / line out
```

`nearmic-link.sh` discovers ports at runtime:

```sh
pw-link -o | grep '^nearmic:'       # nearmic:capture_MONO
pw-link -i | grep -Ei 'uac2|fe800000'  # <sink>:playback_MONO
```

`nearmic-headphone-link.sh` finds the gadget capture source by
`media.class=Audio/Source` plus `UAC2Gadget`/`fe800000` in
`api.alsa.card.name`, `node.name`, `node.description`, or `object.path`, and
the Maono sink by `maono`/`prostudio`.

```sh
pw-link -o | grep -Ei 'uac2|fe800000'  # <source>:capture_FL, capture_FR
pw-link -i | grep -i maono             # <sink>:playback_FL, playback_FR
```

PipeWire handles the graph clock/resampling between the USB mic, the UAC2
gadget and the Maono interface. Do not create a second link from a gadget
monitor or from `nearmic-listen`, and never link the Maono capture source or
the NearMic source back into the Maono sink.

## 24/7 policy

- **Realtime scheduling is required.** The Armbian kernel has
  `CONFIG_RT_GROUP_SCHED`; with cgroup v2 it refuses `SCHED_FIFO` to every
  process outside the root cgroup, so PipeWire and NearMic ran at normal
  priority ("SCHED_FIFO 10 not granted (PERM)") and the 128-frame graph missed
  about four cycles a second. Each miss is a 3-4 ms hole: the "robotic"
  microphone. `rt_group_sched=0` in `extraargs` (`/boot/armbianEnv.txt`, set by
  `apply-appliance.sh` and the image) fixes it. Check with
  `ps -eLo cls,rtprio,comm | grep -E "data-loop|nearmic"`: the graph threads
  must be `FF`. Measured on the operator's far-field recording through the
  live path: DNSMOS OVRL 2.77 before, 3.11 after (offline reference 3.12).
- CPU frequency: `rockpi4/config/cpufrequtils` -> `/etc/default/cpufrequtils`
  (`performance`, 1416-1800 MHz, applied by Armbian to both clusters). The A53
  cluster hosts PipeWire's graph thread and must not idle at 408 MHz.
- `loginctl enable-linger mariogk` so user PipeWire, WirePlumber, NearMic and
  the link services start at boot without an SSH login.
- `nearmic.service`: `Restart=always`, `RestartSec=2`, `Nice=-10`,
  `LimitRTPRIO=95`, `LimitMEMLOCK=infinity`. Its `ExecStartPre` runs
  `nearmic-default-sink` so the UAC2 gadget is the WirePlumber default sink
  before NearMic creates its source; without that, WirePlumber auto-links the
  processed source to the Maono headphones.
- `nearmic-link.service`: `Restart=always`, `RestartSec=2`; it exits when
  either node disappears so systemd re-links after a replug or restart. It
  also sets the gadget as the default sink and prunes any NearMic source link
  to a sink other than the UAC2 gadget.
- `nearmic-headphone-link.service`: `Restart=always`, `RestartSec=2`; same
  wait/exit/re-link behaviour for the UAC2 capture source and Maono sink. If
  the route breaks it removes the links and **mutes the Maono output** before
  exiting, because the interface turns a broken UAC2 stream into a loud
  high-pitched tone. The mute flag is `$XDG_RUNTIME_DIR/nearmic-maono-muted`,
  so only a mute applied by these scripts is ever undone.
- `nearmic-health.timer`: user timer, first run 45 s after boot then every
  60 s. It restarts the gadget/units if they are down, restarts NearMic if it
  is active but `streaming=0`, re-applies the default sink, re-creates a
  missing fixed route, restores the 128-frame quantum after a PipeWire restart,
  and undoes the error mute once the passthrough is real again. It also forces
  the gadget sink to volume 1.0: WirePlumber restored it at 0.46 once, which
  made the whole microphone quiet even though the DSP was at full level. It
  prints nothing while the board is healthy.
- USB link self-repair (in `nearmic-health`): if the UDC sits in a half-open
  state (`default`, `addressed`, `powered`, `attached`) on two checks in a
  row, it pulses `soft_connect`. After the computer suspended and resumed on
  2026-11-11 the link stayed in `default` and the computer had no NearMic
  device for over two hours until it was re-attached.
- `nearmic-gadget.service`: system oneshot, `RemainAfterExit=yes`,
  `Restart=no`. A failure means the overlay/UDC is wrong; restarting would
  hide it.
- systemd hardware watchdog: `RuntimeWatchdogSec=15s` (`/dev/watchdog0`,
  Synopsys DesignWare watchdog).
- Do not run `powertop --auto-tune`; it re-enables USB autosuspend and can
  cause dropouts. Use a per-device udev rule if needed.
- Maintenance reboot window is **04:00** local time, driven by
  `unattended-upgrades`. The board's timezone is `America/Sao_Paulo`, copied
  from the workstation by `prepare-image.sh`, so this is 04:00 local and not
  UTC. The host will see the microphone disconnect during that window.
- `nearmic-wifi-watchdog.timer` runs every 60 s, first run 90 s after boot.
  After 2 min without the Wi-Fi gateway it restarts `netplan-wpa-wlan0.service`
  and reconfigures `wlan0`; after 5 min it runs `netplan apply`; after 10 min it
  replugs the USB adapter. It never reboots the board and logs to the journal
  with tag `nearmic-wifi`. It also keeps Wi-Fi power save off.
  `rockpi4/udev/70-nearmic-wifi.rules` starts `netplan-wpa-wlan0.service` as soon
  as `wlan0` appears, because netplan only pulls that unit in at boot; an
  adapter plugged in later otherwise stayed unassociated.
- `nearmic-uboot-guard.service`: oneshot at boot. It keeps the eMMC first in the
  U-Boot boot order (see [Boot chain](#boot-chain)).
- `rockpi4/systemd/apt-background.conf` drop-in on `apt-daily`,
  `apt-daily-upgrade` and `unattended-upgrades`: `CPUAffinity=0-3`, `Nice=19`,
  idle CPU and I/O class. An apt run was seen at 90 % on an A72 core that NearMic
  uses.
- A Wi-Fi outage never restarts audio. The watchdog touches only `wlan0` and its
  adapter, and no NearMic, gadget or link unit depends on the network (none
  references `network-online.target`).
- `nearmic-cpufreq.service` applies the same policy as
  `/etc/default/cpufrequtils` at install time and at boot. Armbian's
  `armbian-hardware-optimize` applies that file in the background after its
  unit finishes, which is why the unit alone could not hold a policy.
- `config/99-nearmic-sysctl.conf`: a kernel panic or oops reboots the board after
  10 s (`kernel.panic = 10`, `kernel.panic_on_oops = 1`).
- Image only (`prepare-image.sh`): journald is persistent with a 200 MB cap
  (`SystemMaxUse=200M`), Armbian's 50 MB RAM log is disabled, and the kernel
  command line gets `fsck.repair=yes` so a dirty filesystem never stops the boot
  at a prompt.

## Latency budget

The microphone path is tuned for the shortest delay from speech to the host,
not for the lowest CPU. Measured on the board:

| Stage | Setting | Latency |
| --- | --- | --- |
| DeepFilterNet3 | 480-sample hop, 2 hops of look-ahead | 30.0 ms |
| Frame adapter | 480-sample engine frame in the 256-sample worker hop | 10.0 ms |
| Look-ahead limiter | 256 samples | 5.3 ms |
| NearMic output ring | servo target 768 frames, stop at 1536 | ~16 ms |
| PipeWire graph | `clock.force-quantum = 128` frames | 2.7 ms |
| **Through NearMic, measured** | click pairs, direct path vs bypass path | **66.7 ms** (72.0 ms before 2026-11-11) |

The measurement (`/tmp/lat.sh` method: clicks sent to the computer directly
and through NearMic in bypass mode, spacing read from the computer's
recording) covers everything NearMic adds. RNNoise would be 20 ms less
(no look-ahead) at lower quality. Captured audio that queues in front of the
DSP beyond 20 ms is dropped instead of played late.

- `nearmic-default-sink` sets `clock.force-quantum 128` on every start and
  `nearmic-health` restores it after a PipeWire restart.
- `rockpi4/wireplumber/51-nearmic-latency.conf` sets
  `session.suspend-timeout-seconds = 0` and `node.pause-on-idle = false` for
  the gadget and Maono nodes. An idle node stays open instead of being closed
  and reopened, which is what used to cause the heard "activation" delay.
- `src/asrc.zig` must keep its invariants: `1 <= pos` and `pos + 2 < len`
  while `canRead()` is true. A compaction bug that dropped more samples than
  were buffered crashed the service with SIGSEGV every few seconds; the
  systemd restart hid it. `zig build test` covers starvation and full-buffer
  cases.
- Optional, on the host computer: `rockpi4/host/nearmic-host-keepalive.sh`
  keeps one silent consumer on the host's NearMic source so the USB node never
  idles. Without it the host may resume the node when an application opens the
  microphone.

## Automatic apt policy

`apply-appliance.sh --apply` installs:

- `/etc/apt/apt.conf.d/20auto-upgrades` — daily update, download, unattended
  upgrade, weekly autclean.
- `/etc/apt/apt.conf.d/50unattended-upgrades` — **all origins** (`origin=*`),
  no package blacklist, remove unused kernels/dependencies, automatic reboot
  at **04:00**, no AC/metered gating.
- `/etc/needrestart/conf.d/99-nearmic.conf` — automatic service restarts after
  library upgrades, no interactive prompt.
- `unattended-upgrades` and `needrestart` packages if missing.
- `/etc/apt/apt.conf.d/99nearmic-uboot-guard` — re-applies the U-Boot boot order
  after every dpkg run.
- `/etc/systemd/system/{apt-daily,apt-daily-upgrade,unattended-upgrades}.service.d/99-nearmic-background.conf`
  — keeps apt on the A53 cores at idle priority (`CPUAffinity=0-3`, `Nice=19`).

This is intentionally aggressive for a dedicated appliance on a trusted LAN.
The automatic reboot policy is deliberate and should stay enabled:
`Automatic-Reboot`, `Automatic-Reboot-WithUsers` and
`Automatic-Reboot-Time "04:00"` are all required, and
`Automatic-Reboot-WithUsers "true"` is what makes the reboot happen even
though `mariogk` holds a lingering session. Keep it that way when editing the
policy, and re-apply the policy with `apply-appliance.sh --apply` after a
change so the board converges without a manual step.

## Verification commands

Board:

```sh
ssh mariogk@10.10.10.39

# overlay / gadget (also check the physical OTG/Device slide switch)
ls /sys/class/udc
cat /proc/device-tree/usb@fe800000/usb@fe800000/dr_mode | tr -d '\0'
cat /proc/device-tree/usb@fe800000/usb@fe800000/maximum-speed | tr -d '\0'
systemctl status nearmic-gadget --no-pager
lsusb                       # board host ports
aplay -l                    # must show UAC2Gadget playback (mono S16_LE)
arecord -l                  # must show UAC2Gadget capture (stereo) + USB microphone

# PipeWire / NearMic
systemctl --user status pipewire wireplumber nearmic nearmic-link nearmic-headphone-link --no-pager
wpctl status
pw-link -o | grep '^nearmic:'       # nearmic:capture_MONO
pw-link -i | grep -Ei 'uac2|fe800000'  # <sink>:playback_MONO
pw-link -o | grep -Ei 'uac2|fe800000'  # <source>:capture_FL, capture_FR
pw-link -i | grep -i maono             # <sink>:playback_FL, playback_FR
pw-link -l
nearmic status
journalctl --user -u nearmic -u nearmic-link -u nearmic-headphone-link -n 100 --no-pager

# boot/apt/watchdog
systemctl show -p RuntimeWatchdogUSec
systemctl list-timers 'apt-daily*'

# dashboard (Wi-Fi address; 192.168.77.1 over the USB link)
curl -s http://10.10.10.39/api | head -c 300
```

Host computer:

```sh
lsusb | grep -i 1209:4e4d
arecord -l                  # must show NearMic / UAC2Gadget capture (mono)
aplay -l                    # must show NearMic / UAC2Gadget playback (stereo)
arecord -D plughw:CARD=UAC2Gadget,DEV=0 -f S16_LE -r 48000 -c 1 -d 10 /tmp/nearmic-test.wav
aplay /tmp/nearmic-test.wav

# headphone passthrough: select the NearMic/UAC2 playback device as the
# computer output, then play anything; the board links it to the Maono output.
pactl list short sinks | grep -i near
paplay --device=<nearmic-sink> /usr/share/sounds/alsa/Front_Center.wav
```

On the board, the passthrough can be verified without analog capture by
recording the gadget capture source while the host plays a tone:

```sh
pw-record --target <uac2-source-node> --rate 48000 --channels 2 \
  --format s16 /tmp/headphone-test.wav
```

No network (the USB cable is the way in):

```sh
# host computer
lsusb | grep 1209:4e4d
ip -br link | grep -i 02:4e:4d:00:00:02   # host side of the CDC-NCM link
ssh mariogk@192.168.77.1

# board, when Wi-Fi is down
networkctl status wlan0 --no-pager
journalctl -t nearmic-wifi -n 50 --no-pager
systemctl list-timers nearmic-wifi-watchdog.timer --no-pager
```

If `nearmic doctor` reports `pipewire_library=missing`, rebuild the gnu
fallback, redeploy, and restart the user service.
