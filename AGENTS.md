# AGENTS.md — NearMic ROCK 4 Plus USB microphone appliance

This file is the contract for an agent working in this repository and for the
operator maintaining the board. Read it before changing deploy files, the
board's audio graph, or its systemd units.

## Goal

Turn a Radxa ROCK 4 Plus v1.73 into a 24/7 **USB microphone cleaner**:

```
USB microphone
  -> ROCK 4 Plus host USB port
  -> PipeWire
  -> NearMic (Zig, RNNoise + voice post, rock-pi-plus profile)
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
USB Audio Class 2 device (`1209:4e4d`, strings "NearMic") with one mono
microphone and one stereo playback device.

## Board and network

| Item | Value |
| --- | --- |
| Board | Radxa ROCK 4 Plus v1.73 (ROCK 4B+/4A+ PCB), RK3399 |
| SoC | Rockchip OP1 / RK3399, 2x Cortex-A72 + 4x Cortex-A53, no NPU |
| OS | Armbian 26.8.1, Debian 13 Trixie Minimal, kernel 6.18.44 |
| Storage | 32 GB eMMC, root on `/dev/mmcblk0p1` |
| Address | `10.10.10.36` (DHCP, VLAN 10) |
| DNS | `rockpi-4bplus.homelab.lan` |
| Network | Ethernet `end0`, 1 Gbps |
| Login | `mariogk`, SSH key, passwordless sudo |
| Audio | PipeWire + WirePlumber as the `mariogk` user, 48 kHz |

The board is wired only: Ethernet `end0` is the single network interface. See
[rockpi4/README.md](rockpi4/README.md).

**Never write credentials, SSH private keys, tokens, or router passwords into
a tracked file.** `rockpi4/credentials.txt` is local and git-ignored. Keep any
generated credentials out of git.

## Hardware topology and USB port map

| Physical port | Controller / DT node | Role |
| --- | --- | --- |
| Upper USB 3.0 Type-A | OTG0, `usbdrd3_0`, `/usb@fe800000/usb@fe800000` | **Peripheral/gadget** to the host computer |
| Lower USB 3.0 Type-A | OTG1, `usbdrd3_1`, `/usb@fe900000/usb@fe900000` | Host, for the USB microphone |
| USB 2.0 Type-A ports | `usb_host0_*` / `usb_host1_*` (`fe380000`, `fe3c0000`) | Host, for the USB microphone |
| USB-C | Power only | 5 V/3 A supply; not a data port |

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

## Repo layout

| Path | Purpose |
| --- | --- |
| `src/` | Zig source; **do not change for appliance work** |
| `build.zig` | Build definition; **do not change for appliance work** |
| `rockpi4/` | Board image, deployment, appliance config |
| `rockpi4/AUDIO.md` | Detailed gadget/PipeWire design and runbook |
| `rockpi4/SETUP.md` | File-to-destination map and install steps |
| `rockpi4/dtb/` | NearMic OTG overlay |
| `rockpi4/scripts/setup-uac2-gadget.sh` | configfs UAC2 gadget setup/stop |
| `rockpi4/scripts/nearmic-link.sh` | PipeWire source-to-gadget-sink supervisor; sets the gadget default sink and prunes foreign source links |
| `rockpi4/scripts/nearmic-default-sink.sh` | `ExecStartPre` helper: make the UAC2 gadget the WirePlumber default sink |
| `rockpi4/QUALITY.md` | RNNoise/LocalVQE/DPDFNet analysis, old robotic-chain root cause, measurements, build |
| `rockpi4/scripts/nearmic-headphone-link.sh` | UAC2 capture-to-Maono playback passthrough supervisor |
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
ssh mariogk@10.10.10.36 'mkdir -p ~/.local/bin'
scp zig-out/bin/nearmic mariogk@10.10.10.36:~/.local/bin/nearmic
ssh mariogk@10.10.10.36 'chmod 0755 ~/.local/bin/nearmic'

# copy only the deploy tree (work/ is large and git-ignored)
rsync -a --exclude work --exclude credentials.txt \
  rockpi4/ mariogk@10.10.10.36:/tmp/nearmic-rockpi4/

# dry run first, then apply; no reboot is performed
ssh mariogk@10.10.10.36 \
  'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh'
ssh mariogk@10.10.10.36 \
  'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply'
```

If the overlay was just installed, reboot the board **only after coordination**
(see safety rules). The gadget service will fail with a clear message until
`/sys/class/udc/fe800000.usb` exists.

Do not run `nearmic setup` after `apply-appliance.sh`: it rewrites
`~/.config/systemd/user/nearmic.service` from `src/install.zig` and drops the
appliance restart/priority limits. Re-run the installer or edit the installed
unit.

## NearMic profile

`~/.config/nearmic/config.toml` on the board:

```toml
profile = "rock-pi-plus"
engine = "rnnoise"
mode = "suppress"
listen = false
gain_db = 10
source = ""          # set to the USB mic's PipeWire node.name
threads = 1
cpu_budget = 0.80
```

- `profile = "rock-pi-plus"` sets the RK3399 budget. RNNoise is single-threaded,
  so the appliance pins `threads = 1` and `cpu_budget = 0.80`; the user allows
  up to 80 % CPU, but a heavier full-band model is not available on aarch64.
- `engine = "rnnoise"` is the best full-band 48 kHz neural denoiser that builds
  and runs on this board. `voice.Post` adds a 75 Hz high-pass, low shelf,
  +2 dB presence shelf, downward-only leveler and soft limiter. The legacy
  `dsp`/`dsp-dereverb` engines remain selectable but are not the default. See
  [rockpi4/QUALITY.md](rockpi4/QUALITY.md).
- `gain_db = 10` is the RNNoise makeup gain; the post leveler is downward-only.
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
  -> NearMic worker: RNNoise + voice post, 480-sample frame
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
  wait/exit/re-link behaviour for the UAC2 capture source and Maono sink.
- `nearmic-gadget.service`: system oneshot, `RemainAfterExit=yes`,
  `Restart=no`. A failure means the overlay/UDC is wrong; restarting would
  hide it.
- systemd hardware watchdog: `RuntimeWatchdogSec=15s` (`/dev/watchdog0`,
  Synopsys DesignWare watchdog).
- Do not run `powertop --auto-tune`; it re-enables USB autosuspend and can
  cause dropouts. Use a per-device udev rule if needed.
- Maintenance reboot window is **04:00** local time, driven by
  `unattended-upgrades`. The host will see the microphone disconnect during
  that window.

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

This is intentionally aggressive for a dedicated appliance on a trusted LAN.
Review enabled apt sources before adding third-party repositories. Do not
disable the reboot policy without an operator decision.

## Safety rules

1. **No secrets.** Never add passwords, private keys, API tokens, or router
   credentials to tracked files. `rockpi4/credentials.txt` stays local
   and git-ignored. Report accidental secrets; do not commit them.
2. **No HomeLab router changes.** Do not change DHCP reservations, VLANs,
   firewall rules, DNS, or the HomeLab router. The board uses DHCP on VLAN 10.
3. **No reboot without coordination.** The overlay and kernel/watchdog changes
   need a reboot. Ask the operator first; the board is a 24/7 audio path.
4. **No destructive changes without confirmation.** Do not repartition,
   reflash eMMC, change the bootloader, remove `/boot/armbianEnv.txt`, or run
   `rm -rf` on `/boot`, `/etc`, or the repo. Back up `armbianEnv.txt` before
   editing; the installer does this as `armbianEnv.txt.nearmic.bak`.
5. **Do not modify `src/` or `build.zig` for appliance work.** The DSP and
   build gates are owned by the NearMic project; this task is deployment.
6. **Do not run `apt` on the operator workstation.** Package installation
   belongs on the board, through `apply-appliance.sh --apply`.
7. **Do not apply board changes from an agent session without an explicit
   instruction.** Writing repo files is safe; changing the live board is not.
8. **Do not restart PipeWire casually.** Restarting `nearmic` and
   `nearmic-link` is enough after config changes. A PipeWire restart can drop
   all user audio.
9. Keep the gadget and link units idempotent. Re-running the installer must not
   create duplicate links or duplicate `user_overlays` entries.
10. Keep the upper OTG port dedicated to the gadget. The microphone belongs on
    a host port.

## Verification commands

Board:

```sh
ssh mariogk@10.10.10.36

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

If `nearmic doctor` reports `pipewire_library=missing`, rebuild the gnu
fallback, redeploy, and restart the user service.
