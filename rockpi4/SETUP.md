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

# optional: do not install packages, only copy config/units
sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply --skip-packages
```

It never reboots. The OTG overlay requires one coordinated reboot; the script
prints a warning and the gadget service stays disabled until a UDC exists.

The installer installs missing packages (`pipewire`, `wireplumber`,
`pipewire-audio`, `alsa-utils`, `unattended-upgrades`, `needrestart`), copies
the files below, enables lingering for `mariogk`, starts the gadget if a UDC is
present, and enables the user PipeWire/WirePlumber/NearMic/link units
(`nearmic`, `nearmic-link`, `nearmic-headphone-link`).

Set `NEARMIC_USER` to install for a user other than `mariogk`. Set
`NEARMIC_BINARY=/path/to/nearmic` if the release binary is not at
`rockpi4/../zig-out/bin/nearmic`.

## File map

| Repo file | On-board destination | Mode / owner | Purpose |
| --- | --- | --- | --- |
| `dtb/nearmic-otg.dts` | (source only; not installed directly) | — | OTG0 peripheral overlay source |
| `dtb/nearmic-otg.dtbo` | `/boot/overlay-user/nearmic-otg.dtbo` | `0644 root:root` | Compiled overlay: `dr_mode=peripheral`, `maximum-speed=high-speed` |
| (edits `/boot/armbianEnv.txt`) | `user_overlays=nearmic-otg` | `0644 root:root` | U-Boot applies the user overlay; backup is `armbianEnv.txt.nearmic.bak` |
| `scripts/setup-uac2-gadget.sh` | `/usr/local/sbin/nearmic-gadget-setup` | `0755 root:root` | configfs duplex UAC2 gadget start/stop/check |
| `systemd/nearmic-gadget.service` | `/etc/systemd/system/nearmic-gadget.service` | `0644 root:root` | System oneshot, before user PipeWire; `Restart=no` |
| `scripts/nearmic-link.sh` | `~/.local/bin/nearmic-link` | `0755 mariogk` | Wait for `nearmic` + UAC2 sink, `pw-link`, supervise |
| `systemd/nearmic-link.service` | `~/.config/systemd/user/nearmic-link.service` | `0644 mariogk` | User link supervisor, `Restart=always` |
| `scripts/nearmic-default-sink.sh` | `~/.local/bin/nearmic-default-sink` | `0755 mariogk` | `ExecStartPre` helper: UAC2 gadget as default sink |
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
| `AUDIO.md` | `/usr/local/share/doc/nearmic/AUDIO.md` | `0644 root:root` | On-board runbook (unit `Documentation=`) |
| `SETUP.md` | `/usr/local/share/doc/nearmic/SETUP.md` | `0644 root:root` | On-board file map |

The NearMic binary is not built by the installer. Put it at
`~/.local/bin/nearmic` first:

```sh
ssh mariogk@10.10.10.36 'mkdir -p ~/.local/bin'
scp zig-out/bin/nearmic mariogk@10.10.10.36:~/.local/bin/nearmic
ssh mariogk@10.10.10.36 'chmod 0755 ~/.local/bin/nearmic'
```

## Required hardware state

1. **OTG slide switch** on the underside, below the USB ports: set to
   **OTG/Device**. In Host position the upper USB 3.0 port cannot enumerate as
   a device.
2. USB-C power supply connected.
3. USB-A male to USB-A male **data** cable from the upper USB 3.0 Type-A port
   to the host computer.
4. USB microphone on the lower USB 3.0 Type-A port or either USB 2.0 Type-A
   port. Do not use the upper port for the microphone.
5. Ethernet connected.

## First install order

```sh
# 1. Build on the workstation (see AGENTS.md for musl/gnu fallback)
zig build -Dtarget=aarch64-linux-musl -Dcpu=cortex_a53 -Doptimize=ReleaseFast

# 2. Copy the binary
ssh mariogk@10.10.10.36 'mkdir -p ~/.local/bin'
scp zig-out/bin/nearmic mariogk@10.10.10.36:~/.local/bin/nearmic

# 3. Copy the deploy tree (work/ and credentials.txt are not needed)
rsync -a --exclude work --exclude credentials.txt \
  rockpi4/ mariogk@10.10.10.36:/tmp/nearmic-rockpi4/

# 4. Dry run, then apply
ssh mariogk@10.10.10.36 'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh'
ssh mariogk@10.10.10.36 'sudo /tmp/nearmic-rockpi4/scripts/apply-appliance.sh --apply'

# 5. Coordinate the reboot (required for the overlay)
ssh mariogk@10.10.10.36 'sudo reboot'
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

Edit `~/.config/nearmic/config.toml`:

```toml
profile = "rock-pi-plus"
engine = "rnnoise"
mode = "suppress"
listen = false
gain_db = 10
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
install -D -m 0644 systemd/nearmic-headphone-link.service ~/.config/systemd/user/nearmic-headphone-link.service
sudo systemctl daemon-reload
sudo systemctl enable --now nearmic-gadget.service
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now pipewire.socket pipewire.service wireplumber.service
systemctl --user enable --now nearmic.service nearmic-link.service nearmic-headphone-link.service
```

Then install the apt, watchdog, and limits files from the table and reboot for
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
- No reboot without coordination; the board is a 24/7 audio path.
- Do not modify `src/` or `build.zig` for appliance work.
- Do not run `powertop --auto-tune` (USB autosuspend causes dropouts).
- The automatic reboot window is **04:00**; the host will see the microphone
  disconnect then.
