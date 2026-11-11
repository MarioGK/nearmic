# NearMic appliance — setup and file map

This is the install map for the 24/7 USB microphone appliance. The detailed
design and test plan are in [AUDIO.md](AUDIO.md). Agent rules are in
[../AGENTS.md](../AGENTS.md).

## What the installer does

`scripts/apply-appliance.sh` is idempotent. It defaults to a dry run and only
changes the board with `--apply`:

```sh
# from the board, after copying rockpi4/ to /tmp/nearmic-rockpi4
sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh
sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply

# apply and reboot in one step (required when the overlay is new)
sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply --reboot

# optional: do not install packages, only copy config/units
sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply --skip-packages
```

Without `--reboot` it never reboots; `--reboot` syncs and issues
`systemctl reboot --no-block` after the apply step, so the board converges
without a second interactive round trip. The OTG overlay requires that reboot;
until a UDC exists the script prints a warning, and the gadget service is
enabled but not started.

The installer installs missing packages (`pipewire`, `wireplumber`,
`pipewire-audio`, `alsa-utils`, `unattended-upgrades`, `needrestart`), copies
the files below, enables lingering for `mariogk`, starts the gadget if a UDC is
present, and enables the user PipeWire/WirePlumber/NearMic/link units
(`nearmic`, `nearmic-link`, `nearmic-headphone-link`). It also enables the CPU
policy (`nearmic-cpufreq`), the Wi-Fi watchdog timer and the panic sysctl. It
also installs and enables the dashboard (`nearmic-dash`), the U-Boot boot-order
guard (`nearmic-uboot-guard`), the apt background drop-in and the Wi-Fi hotplug
rule. It creates `~/.local` and `~/.config/systemd` owned by the user: they were
root-owned before, and WirePlumber could not write `~/.local/state`.

Set `NEARMIC_USER` to install for a user other than `mariogk`. Set
`NEARMIC_BINARY=/path/to/nearmic` if the release binary is not at
`rockpi4/../zig-out/bin/nearmic`.

## File map

| Repo file | On-board destination | Mode / owner | Purpose |
| --- | --- | --- | --- |
| `dtb/nearmic-otg.dts` | (source only; not installed directly) | — | OTG0 peripheral overlay source |
| `dtb/nearmic-otg.dtbo` | `/boot/overlay-user/nearmic-otg.dtbo` | `0644 root:root` | Compiled overlay: `dr_mode=peripheral`, `maximum-speed=high-speed` |
| (edits `/boot/armbianEnv.txt`) | `user_overlays=nearmic-otg` | `0644 root:root` | U-Boot applies the user overlay; backup is `armbianEnv.txt.nearmic.bak` |
| `scripts/setup-uac2-gadget.sh` | `/usr/local/sbin/nearmic-gadget-setup` | `0755 root:root` | configfs duplex UAC2 gadget start/stop/check, plus a CDC-NCM maintenance network; CDC-ACM is tried first and dropped on the verified build |
| `systemd/nearmic-gadget.service` | `/etc/systemd/system/nearmic-gadget.service` | `0644 root:root` | System oneshot, before user PipeWire; `Restart=no` |
| `scripts/nearmic-link.sh` | `~/.local/bin/nearmic-link` | `0755 mariogk` | Wait for `nearmic` + UAC2 sink, `pw-link`, supervise |
| `systemd/nearmic-link.service` | `~/.config/systemd/user/nearmic-link.service` | `0644 mariogk` | User link supervisor, `Restart=always` |
| `scripts/nearmic-default-sink.sh` | `~/.local/bin/nearmic-default-sink` | `0755 mariogk` | `ExecStartPre` helper: UAC2 gadget default sink + 128-frame quantum |
| `scripts/nearmic-health.sh` | `~/.local/bin/nearmic-health` | `0755 mariogk` | 24/7 self check run by the health timer |
| `systemd/nearmic-health.service` | `~/.config/systemd/user/nearmic-health.service` | `0644 mariogk` | One-shot health check unit |
| `systemd/nearmic-health.timer` | `~/.config/systemd/user/nearmic-health.timer` | `0644 mariogk` | Every 60 s, first run 45 s after boot |
| `wireplumber/51-nearmic-latency.conf` | `/etc/wireplumber/wireplumber.conf.d/51-nearmic-latency.conf` | `0644 root` | No suspend-on-idle, 128-frame ALSA periods |
| `host/nearmic-host-keepalive.sh` | `~/.local/bin/nearmic-host-keepalive` on the **host** | `0755` | Optional: keep the host's NearMic source streaming |
| `host/nearmic-host-keepalive.service` | `~/.config/systemd/user/nearmic-host-keepalive.service` on the **host** | `0644` | Optional host user unit for the keepalive |
| `scripts/nearmic-headphone-link.sh` | `~/.local/bin/nearmic-headphone-link` | `0755 mariogk` | Wait for UAC2 capture + Maono sink, `pw-link` stereo passthrough, supervise |
| `systemd/nearmic-headphone-link.service` | `~/.config/systemd/user/nearmic-headphone-link.service` | `0644 mariogk` | User headphone link supervisor, `Restart=always` |
| `systemd/nearmic.service` | `~/.config/systemd/user/nearmic.service` | `0644 mariogk` | Full NearMic unit: `Restart=always`, `Nice=-10`, RT/memlock limits |
| `systemd/user@.service.d/99-nearmic-limits.conf` | `/etc/systemd/system/user@.service.d/99-nearmic-limits.conf` | `0644 root:root` | Gives the lingering user manager the hard limits |
| `config/99-nearmic-limits.conf` | `/etc/security/limits.d/99-nearmic-limits.conf` | `0644 root:root` | PAM limits for interactive sessions |
| `config/nearmic-config.toml` | `~/.config/nearmic/config.toml` | `0644 mariogk` | Installed only if absent; preserves existing config |
| `apt/20auto-upgrades` | `/etc/apt/apt.conf.d/20auto-upgrades` | `0644 root:root` | Daily apt update/download/unattended upgrade |
| `apt/50unattended-upgrades` | `/etc/apt/apt.conf.d/50unattended-upgrades` | `0644 root:root` | All origins, cleanup, reboot at 04:00 |
| `apt/needrestart.conf` | `/etc/needrestart/conf.d/99-nearmic.conf` | `0644 root:root` | Automatic service restarts, no prompt |
| `systemd/watchdog.conf` | `/etc/systemd/system.conf.d/99-nearmic-watchdog.conf` | `0644 root:root` | `RuntimeWatchdogSec=15s` |
| `config/99-nearmic-sysctl.conf` | `/etc/sysctl.d/99-nearmic.conf` | `0644 root:root` | Kernel panic and oops reboot after 10 s |
| `network/10-nearmic-usb-wifi.link` | `/etc/systemd/network/10-nearmic-usb-wifi.link` | `0644 root:root` | Names the USB Wi-Fi adapter `wlan0` |
| `network/30-nearmic-usb0.network` | `/etc/systemd/network/30-nearmic-usb0.network` | `0644 root:root` | USB maintenance link `usb0` 192.168.77.1/24, DHCP for the host |
| `udev/70-nearmic-wifi.rules` | `/etc/udev/rules.d/70-nearmic-wifi.rules` | `0644 root:root` | Wi-Fi power save off, no USB autosuspend for the adapter; starts `netplan-wpa-wlan0` when `wlan0` appears |
| `systemd/nearmic-cpufreq.service` | `/etc/systemd/system/nearmic-cpufreq.service` | `0644 root:root` | A72 policy: `ondemand`, 1416000-1608000 kHz |
| `scripts/nearmic-wifi-watchdog.sh` | `/usr/local/sbin/nearmic-wifi-watchdog` | `0755 root:root` | Wi-Fi self-repair; never reboots the board |
| `systemd/nearmic-wifi-watchdog.service` | `/etc/systemd/system/nearmic-wifi-watchdog.service` | `0644 root:root` | Oneshot run by the timer |
| `systemd/nearmic-wifi-watchdog.timer` | `/etc/systemd/system/nearmic-wifi-watchdog.timer` | `0644 root:root` | Every 60 s, first run 90 s after boot |
| `systemd/nearmic-firstboot.service` | `/etc/systemd/system/nearmic-firstboot.service` (image only) | `0644 root:root` | Runs `apply-appliance.sh --apply --skip-packages` once, then the engine guard |
| `scripts/nearmic-engine-guard.sh` | `/opt/nearmic/scripts/nearmic-engine-guard.sh` (image only) | — | Times DeepFilterNet on a 10 s clip; falls back to RNNoise if not realtime |
| `scripts/prepare-image.sh` | (workstation only) | — | Builds `rockpi4/work/nearmic-<date>.img` with Wi-Fi, gadget and first boot |
| `scripts/rk.sh` | (workstation only) | — | Mask ROM `wait`/`flash`/`backup`/`stress` over `rkdeveloptool` |
| `.env` | (workstation only, git-ignored) | — | `WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY` read by `prepare-image.sh` |
| `dash/nearmic-dash.py`, `dash/index.html` | `/usr/local/share/nearmic/dash/` | `0755` / `0644 root:root` | NearMic Console: live page and JSON on port 80 |
| `systemd/nearmic-dash.service` | `/etc/systemd/system/nearmic-dash.service` | `0644 root:root` | Dashboard unit: user `mariogk`, `CAP_NET_BIND_SERVICE`, A53 cores, `Nice=10`, 96 MB cap |
| `scripts/nearmic-uboot-guard.py` | `/usr/local/sbin/nearmic-uboot-guard` | `0755 root:root` | Re-applies the eMMC-first U-Boot boot order to the eMMC boot area and `/usr/lib/linux-u-boot-*/u-boot.itb` |
| `systemd/nearmic-uboot-guard.service` | `/etc/systemd/system/nearmic-uboot-guard.service` | `0644 root:root` | Oneshot at boot, enabled by the installer |
| `apt/99nearmic-uboot-guard` | `/etc/apt/apt.conf.d/99nearmic-uboot-guard` | `0644 root:root` | `DPkg::Post-Invoke` hook: runs the guard after every dpkg run |
| `systemd/apt-background.conf` | `/etc/systemd/system/{apt-daily,apt-daily-upgrade,unattended-upgrades}.service.d/99-nearmic-background.conf` | `0644 root:root` | apt and unattended-upgrades on the A53 cores (`CPUAffinity=0-3`), `Nice=19`, idle CPU and I/O |
| `AUDIO.md` | `/usr/local/share/doc/nearmic/AUDIO.md` | `0644 root:root` | On-board runbook (unit `Documentation=`) |
| `SETUP.md` | `/usr/local/share/doc/nearmic/SETUP.md` | `0644 root:root` | On-board file map |

Written only by `prepare-image.sh` (not from the repo): `/etc/netplan/20-nearmic-wifi.yaml`
(`0600`, generated from `.env`), `/etc/modprobe.d/nearmic-wifi.conf` (Wi-Fi regulatory
domain), `/etc/systemd/journald.conf.d/99-nearmic.conf` (persistent journal, 200 MB cap)
and `/etc/default/armbian-ramlog` (`ENABLED=false`).

The NearMic binary is not built by the installer. Put it at
`~/.local/bin/nearmic` first:

```sh
ssh mariogk@10.10.10.39 'mkdir -p ~/.local/bin'
scp zig-out/bin/nearmic mariogk@10.10.10.39:~/.local/bin/nearmic
ssh mariogk@10.10.10.39 'chmod 0755 ~/.local/bin/nearmic'
```

## Required hardware state

1. **OTG slide switch** on the underside, below the USB ports: set to
   **OTG/Device**. In Host position the upper USB 3.0 port cannot enumerate as
   a device.
2. USB-C power supply connected.
3. USB-A male to USB-A male **data** cable from the upper USB 3.0 Type-A port
   to the host computer.
4. Host ports (verified layout): the TP-Link Wi-Fi adapter on one USB 2.0
   Type-A port and the Maono on the other. The lower USB 3.0 port stays unused:
   the Maono failed to enumerate there (`error -71`). Do not use the upper port
   for the microphone.
5. Network: the TP-Link Wi-Fi adapter (`wlan0`), or Ethernet cabled to `end0`.
   The microphone needs neither; the USB maintenance link (`192.168.77.1`) is
   always there when the gadget binds.

## First install order

```sh
# 1. Build on the workstation: glibc aarch64 only (AGENTS.md, "Build")
scripts/build-rnnoise-aarch64.sh
zig build -Dtarget=aarch64-linux-gnu -Dcpu=cortex_a53 -Doptimize=ReleaseFast -Dbundle=true

# 2. Copy the binary
ssh mariogk@10.10.10.39 'mkdir -p ~/.local/bin'
scp zig-out/bin/nearmic mariogk@10.10.10.39:~/.local/bin/nearmic

# 3. Copy the deploy tree (work/ and credentials.txt are not needed)
rsync -a --exclude work --exclude credentials.txt \
  rockpi4/ mariogk@10.10.10.39:/tmp/nearmic-rockpi4/

# 4. Dry run, then apply and reboot in one step
ssh mariogk@10.10.10.39 'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh'
ssh mariogk@10.10.10.39 'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply --reboot'

# or, if you want to inspect the result before rebooting:
ssh mariogk@10.10.10.39 'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply'
ssh mariogk@10.10.10.39 'sudo reboot'
```

After the reboot, verify:

```sh
ls /sys/class/udc
# fe800000.usb

tr -d '\0' < /proc/device-tree/usb@fe800000/usb@fe800000/dr_mode
# peripheral

sudo systemctl status nearmic-gadget --no-pager
aplay -l                 # UAC2Gadget playback (microphone direction)
arecord -l               # USB microphone + UAC2Gadget capture (headphone direction)
systemctl --user status nearmic nearmic-link nearmic-headphone-link --no-pager
pw-link -l
```

On the host computer:

```sh
lsusb | grep -i 1209:4e4d
arecord -l
aplay -l
arecord -D plughw:CARD=UAC2Gadget,DEV=0 -f S16_LE -r 48000 -c 1 -d 10 /tmp/test.wav
aplay /tmp/test.wav
```

For headphone passthrough, select the NearMic/UAC2 playback device as the
computer output; the board forwards it to the Maono interface's headphones:

```sh
pactl list short sinks | grep -i near
pactl set-default-sink <near-mic-uac2-sink>
```

## Configure the real microphone

The appliance cannot know the USB microphone's PipeWire node name in advance.
If `~/.config/nearmic/config.toml` is new, set `source` after the microphone is
plugged in:

```sh
pw-cli ls Node | grep -E 'node.name|media.class'
# find the Audio/Source whose node.name starts with alsa_input.usb-...
```

Edit `~/.config/nearmic/config.toml`. The first-boot engine guard may already
have set `engine = "rnnoise"` and `gain_db = 10` on this board:

```toml
profile = "rock-pi-plus"
engine = "deepfilter"
mode = "suppress"
listen = false
gain_db = 0
threads = 1
cpu_budget = 0.80
source = "alsa_input.usb-....analog-stereo"
```

Then:

```sh
systemctl --user restart nearmic.service nearmic-link.service
```

Leaving `source = ""` captures the default source at daemon start. That is
racy on a headless boot; set it explicitly for a 24/7 appliance.

## Manual install (without the installer)

If you prefer to copy each file yourself, use the destinations in the table
above. The commands below assume the current directory is `rockpi4/`. Minimum
steps:

```sh
sudo install -D -m 0644 dtb/nearmic-otg.dtbo /boot/overlay-user/nearmic-otg.dtbo
# append user_overlays=nearmic-otg to /boot/armbianEnv.txt
sudo install -D -m 0755 scripts/setup-uac2-gadget.sh /usr/local/sbin/nearmic-gadget-setup
sudo install -D -m 0644 systemd/nearmic-gadget.service /etc/systemd/system/nearmic-gadget.service
install -D -m 0755 scripts/nearmic-link.sh ~/.local/bin/nearmic-link
install -D -m 0755 scripts/nearmic-headphone-link.sh ~/.local/bin/nearmic-headphone-link
install -D -m 0644 systemd/nearmic.service ~/.config/systemd/user/nearmic.service
install -D -m 0644 systemd/nearmic-link.service ~/.config/systemd/user/nearmic-link.service
install -D -m 0755 scripts/nearmic-default-sink.sh ~/.local/bin/nearmic-default-sink
install -D -m 0755 scripts/nearmic-health.sh ~/.local/bin/nearmic-health
install -D -m 0644 systemd/nearmic-health.service ~/.config/systemd/user/nearmic-health.service
install -D -m 0644 systemd/nearmic-health.timer ~/.config/systemd/user/nearmic-health.timer
systemctl --user enable --now nearmic-health.timer
install -D -m 0644 systemd/nearmic-headphone-link.service ~/.config/systemd/user/nearmic-headphone-link.service
sudo systemctl daemon-reload
sudo systemctl enable --now nearmic-gadget.service
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now pipewire.socket pipewire.service wireplumber.service
systemctl --user enable --now nearmic.service nearmic-link.service nearmic-headphone-link.service
```

Then install the apt, watchdog, sysctl, network, udev and limits files from the table and reboot for
the overlay. Do not skip the **OTG/Device** physical switch check.

## Re-running and rollback

- Do not run `nearmic setup` after this installer. It rewrites
  `~/.config/systemd/user/nearmic.service` from `src/install.zig` and loses the
  appliance directives (`Restart=always`, `Nice=-10`, RT/memlock limits). Re-run
  `apply-appliance.sh --apply` or edit the installed unit instead.
- Re-running `--apply` is safe: it preserves an existing
  `~/.config/nearmic/config.toml`, does not duplicate `user_overlays`, and
  recreates the gadget idempotently.
- To disable the appliance without removing files:

  ```sh
  systemctl --user disable --now nearmic-headphone-link.service nearmic-link.service nearmic.service
  sudo systemctl disable --now nearmic-gadget.service
  ```

- To roll back the overlay: remove `nearmic-otg` from `user_overlays`, remove
  `/boot/overlay-user/nearmic-otg.dtbo`, and reboot.
- `armbianEnv.txt` is backed up as `armbianEnv.txt.nearmic.bak` on first edit.

## Safety

- No secrets in any file; `credentials.txt` stays local and git-ignored.
- No HomeLab router/DHCP/VLAN/firewall changes.
- eMMC reflash only as a last resort, through `rk.sh` with a `prepare-image.sh`
  image; never repartition by hand (see [AGENTS.md](../AGENTS.md)).
- Rebooting is expected and allowed: deploy, reboot, verify. Use
  `apply-appliance.sh --apply --reboot` when the overlay or kernel path changed.
- Do not modify `src/` or `build.zig` for appliance work.
- Do not run `powertop --auto-tune` (USB autosuspend causes dropouts).
- The automatic reboot window is **04:00**; the host will see the microphone
  disconnect then.
