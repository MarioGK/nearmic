# NearMic audio appliance — UAC2 gadget + PipeWire runbook

This is the exact design for the ROCK 4 Plus v1.73 USB microphone cleaner.
The board turns a real USB microphone into a USB microphone for another
computer. The host computer needs no NearMic install.

```
USB microphone
  -> ROCK 4 Plus host USB port
  -> PipeWire source (alsa_input.usb-...)
  -> NearMic capture stream (nearmic-capture)
  -> NearMic DSP (RNNoise + voice post, rock-pi-plus profile)
  -> NearMic source (node.name "nearmic", capture_MONO)
  -> pw-link
  -> UAC2 gadget sink (ALSA UAC2Gadget, playback_MONO)
  -> dwc3 OTG0 (fe800000.usb, peripheral)
  -> host computer sees a USB microphone (1209:4e4d)
```

The gadget is duplex. The host also sees a stereo speaker; host playback is
passed through to the Maono interface's headphone/line outputs:

```
host computer playback
  -> USB-OUT on the gadget
  -> board ALSA UAC2Gadget capture (capture_FL/FR, stereo S16_LE 48 kHz)
  -> pw-link
  -> Maono playback sink (alsa_output.usb-Maono_..., playback_FL/FR)
  -> headphones / line out
```

That path has no DSP and no `pw-loopback`; it is a direct `pw-link`. The
microphone path and the headphone path are independent, so the host can use
the NearMic microphone while monitoring computer audio.

## 1. Port map and physical switch

| Physical port | Controller | Role |
| --- | --- | --- |
| Upper USB 3.0 Type-A | OTG0, `usbdrd3_0`, `/usb@fe800000/usb@fe800000` | **Device/gadget** to the host computer |
| Lower USB 3.0 Type-A | OTG1, `usbdrd3_1`, `/usb@fe900000/usb@fe900000` | Host, for the USB microphone |
| USB 2.0 Type-A (two) | `usb_host0_*` / `usb_host1_*` (`fe380000`, `fe3c0000`) | Host, for the USB microphone |
| USB-C | Power only | 5 V/3 A supply; never data |

**Check the physical OTG slide switch first.** ROCK 4A/4B boards have a small
switch on the **underside below the USB ports**. It must be in **OTG/Device**
position. In Host position the upper USB 3.0 port stays a host port no matter
what the device tree says. This is the most common "overlay is installed but
`/sys/class/udc` is still empty" cause.

Use a **USB-A male to USB-A male data cable** from the upper port to the host.
A charge-only cable will power the board but will not enumerate. Keep the
USB-C power supply connected; the gadget is bus-powered and the RK3399 board
draws more than a host port guarantees.

## 2. Device tree overlay (required)

The stock Armbian `rk3399-rock-pi-4b-plus.dtb` sets both dwc3 controllers to
`dr_mode = "host"`. The NearMic overlay changes only OTG0:

```dts
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/usb@fe800000/usb@fe800000";
        __overlay__ {
            dr_mode = "peripheral";
            maximum-speed = "high-speed";
            status = "okay";
        };
    };
};
```

Files:

- `rockpi4/dtb/nearmic-otg.dts`
- `rockpi4/dtb/nearmic-otg.dtbo`

`maximum-speed = "high-speed"` selects USB 2.0 High Speed (480 Mbit/s) on the
USB 3.0-capable OTG controller. A UAC2 microphone does not need SuperSpeed, and
High Speed avoids dwc3 SuperSpeed gadget edge cases.

Install:

```sh
sudo install -D -m 0644 rockpi4/dtb/nearmic-otg.dtbo \
  /boot/overlay-user/nearmic-otg.dtbo

# Preferred: apply-appliance.sh --apply preserves existing overlays and is
# idempotent. Manual first-time example:
if grep -q '^user_overlays=' /boot/armbianEnv.txt; then
  grep -q 'nearmic-otg' /boot/armbianEnv.txt ||
    sudo sed -i 's|^user_overlays=\(.*\)|user_overlays=\1 nearmic-otg|' /boot/armbianEnv.txt
else
  echo 'user_overlays=nearmic-otg' | sudo tee -a /boot/armbianEnv.txt
fi
```

If the board already has other user overlays, keep them and append
`nearmic-otg` with a space. `apply-appliance.sh --apply` does this correctly and
backs up the file as `/boot/armbianEnv.txt.nearmic.bak`.

**A reboot is required.** The overlay is applied by U-Boot, not at runtime.
After the reboot:

```sh
ls /sys/class/udc
# fe800000.usb

tr -d '\0' < /proc/device-tree/usb@fe800000/usb@fe800000/dr_mode
# peripheral

tr -d '\0' < /proc/device-tree/usb@fe800000/usb@fe800000/maximum-speed
# high-speed
```

If `/sys/class/udc` is empty after the reboot, check the physical switch and
`dmesg | grep -i dwc3`, then re-check `user_overlays` and the file name. The
lower USB 3.0 port and both USB 2.0 ports remain host ports; only OTG0 changes.

Rollback: remove `nearmic-otg` from `user_overlays`, remove
`/boot/overlay-user/nearmic-otg.dtbo`, and reboot.

## 3. UAC2 configfs gadget

The gadget is created by `rockpi4/scripts/setup-uac2-gadget.sh`, installed as
`/usr/local/sbin/nearmic-gadget-setup`.

Important kernel direction mapping (`f_uac2.c`):

```
USB-OUT  -> IT -> FU -> OT -> ALSA_Capture   (c_chmask)
ALSA_Playback -> IT -> FU -> OT -> USB-IN    (p_chmask)
```

For a **microphone**, the host records from USB-IN. That means the board uses
its **ALSA playback** PCM and the gadget config uses `p_chmask`, not
`c_chmask`. Getting this backwards makes the host see a speaker instead of a
microphone. This gadget is duplex: `p_chmask=1` gives the host its mono
microphone, and `c_chmask=3` gives it a stereo speaker whose samples arrive on
the board's ALSA capture PCM.

| configfs attribute | Value | Meaning |
| --- | --- | --- |
| `p_chmask` | `1` | Mono USB-IN; host records this as its microphone |
| `p_srate` | `48000` | Host capture rate |
| `p_ssize` | `2` | S16_LE (2 bytes/sample) |
| `c_chmask` | `3` | Stereo USB-OUT; host plays to this as its speaker |
| `c_srate` | `48000` | Host playback rate |
| `c_ssize` | `2` | S16_LE |

Other settings:

| Attribute | Value |
| --- | --- |
| `idVendor` | `0x1209` (pid.codes open-source vendor ID) |
| `idProduct` | `0x4e4d` (private/demo "NM") |
| `bcdUSB` | `0x0200` |
| `bcdDevice` | `0x0100` |
| manufacturer | `NearMic` |
| product | `NearMic USB Microphone` |
| serial | `NEARMIC-0001` |
| `MaxPower` | `500` mA |

The script:

1. mounts configfs if needed (`/sys/kernel/config`),
2. loads `libcomposite` and `usb_f_uac2` best-effort,
3. cleans up any stale gadget,
4. writes the attributes above,
5. links `functions/uac2.usb0` into `configs/c.1`,
6. autodetects the UDC from `/sys/class/udc` (preferring `fe800000.usb`),
7. binds by writing the UDC name,
8. exits with a clear message if `/sys/class/udc` is empty or if
   `dr_mode` is not `peripheral`.

On the board this creates an ALSA card named `UAC2Gadget` with a playback PCM
(mono) and a capture PCM (stereo). On the host it creates a USB audio device
with one mono capture stream (the microphone) and one stereo playback stream
(the speaker), both 48 kHz S16_LE.

Manual inspection:

```sh
cat /sys/kernel/config/usb_gadget/nearmic/UDC
cat /sys/kernel/config/usb_gadget/nearmic/functions/uac2.usb0/p_chmask
cat /sys/kernel/config/usb_gadget/nearmic/functions/uac2.usb0/c_chmask
aplay -l                  # UAC2Gadget playback (mic direction)
arecord -l                # UAC2Gadget capture (headphone direction)
cat /proc/asound/cards
```

Do not write `p_srate`/`p_ssize` without first setting `p_chmask`; the kernel
rejects invalid combinations. The kernel validates both directions'
rate/size fields, so always set `c_srate` and `c_ssize`.

## 4. ALSA and PipeWire discovery

### Board ALSA

```sh
cat /proc/asound/cards
arecord -l     # real USB microphone (capture) + UAC2Gadget (stereo capture)
aplay -l       # UAC2Gadget playback (the gadget sink)
```

The USB microphone is a capture device. The gadget exposes both directions:
`aplay` sees `UAC2Gadget` playback (board -> host microphone) and `arecord`
sees `UAC2Gadget` capture (host -> board headphones).

### PipeWire nodes

```sh
systemctl --user status pipewire wireplumber
wpctl status
pw-cli ls Node
pw-cli ls Port
```

Expected NearMic node:

```
node.name        = "nearmic"
node.description = "NearMic"
media.class      = "Audio/Source"
port             = "capture_MONO"
```

The build agent observed the source output port as `capture_MONO` on the glibc
binary. The exact name is a PipeWire implementation detail: `nearmic-link.sh`
enumerates `pw-link -o` and never hardcodes it. Treat `capture_MONO` as the
current observation, not a stable API.

The capture helper is `nearmic-capture`; the optional listen helper is
`nearmic-listen` (disabled by `listen=false`).

Expected gadget sink node (name is platform/card derived; the exact middle can
change between PipeWire versions):

```
media.class = "Audio/Sink"
node.name   ~ "alsa_output.platform-fe800000.usb.UAC2Gadget..."
port        = "playback_MONO"
```

Expected gadget source node (host playback direction):

```
media.class       = "Audio/Source"
api.alsa.card.name = "UAC2_Gadget"
node.name         ~ "alsa_input.platform-fe800000.usb..."
ports             = "capture_FL", "capture_FR"
```

Useful queries:

```sh
pw-link -o | grep '^nearmic:'
# nearmic:capture_MONO

pw-link -i | grep -Ei 'uac2|fe800000'
# <gadget-node>:playback_MONO

pw-link -o | grep -Ei 'uac2|fe800000'
# <gadget-source>:capture_FL
# <gadget-source>:capture_FR

pw-link -i | grep -i maono
# <maono-sink>:playback_FL
# <maono-sink>:playback_FR

wpctl inspect <id>       # node.name, node.description, media.class
pw-cli info <id>
pw-dump                  # JSON, includes api.alsa.card.name
```

If the exact gadget name is different, set `NEARMIC_SINK` in
`nearmic-link.service` to the discovered `node.name`. Do not guess from the
`aplay -l` card name; PipeWire's node name includes the platform path.
`nearmic-headphone-link.sh` auto-detects its two nodes and accepts
`NEARMIC_HEADPHONE_SOURCE`/`NEARMIC_HEADPHONE_SINK` overrides.

NearMic itself publishes `node.name = "nearmic"` and
`node.description = "NearMic"` (see `src/c/pw_glue.c`). Its source stream is
mono F32 at 48 kHz. The script matches the source exactly as `nearmic` and the
sink by `UAC2Gadget`, `UAC2_Gadget`, `NearMic` or `fe800000` in the node
name/description, restricted to `media.class = "Audio/Sink"`.

## 5. PipeWire routing

There are two independent routes, each one explicit link:

```sh
# microphone: board -> host
pw-link nearmic:capture_MONO <gadget-sink>:playback_MONO

# headphones: host -> board -> Maono output
pw-link <gadget-source>:capture_FL <maono-sink>:playback_FL
pw-link <gadget-source>:capture_FR <maono-sink>:playback_FR
```

`nearmic-link.sh` waits for both nodes, creates the first link, and supervises
it. `nearmic-headphone-link.sh` does the same for the two channel links, keeping
FL with FL and FR with FR. No ALSA `snd-aloop` device is needed; the PipeWire
links are the loopback bridge. Neither script uses `pw-loopback`: a loopback
would add another node and make it easy to reverse the direction.

`nearmic-link.sh` only connects an output port of the NearMic source to an
input port of the gadget sink. `nearmic-headphone-link.sh` only connects the
gadget capture outputs to the Maono playback inputs. Neither script connects:

- `UAC2Gadget:monitor_*` (would feed the board's own output back)
- `nearmic:input_*` (NearMic does not expose one)
- `nearmic-listen:*` (disabled; room feedback risk)
- the Maono capture ports or the NearMic source to the Maono sink (feedback)

`pw-link -l` should show the microphone link and the two headphone links:

```
nearmic:capture_MONO
  |-> alsa_output.platform-fe800000.usb.mono-fallback:playback_MONO

alsa_input.platform-fe800000.usb.stereo-fallback:capture_FL
  |-> alsa_output.usb-Maono_ProStudio_2x2_Lite_...:playback_FL

alsa_input.platform-fe800000.usb.stereo-fallback:capture_FR
  |-> alsa_output.usb-Maono_ProStudio_2x2_Lite_...:playback_FR
```

`pw-link -l` prints each destination under its source; the exact node names are
platform-derived and may differ.

PipeWire picks a graph driver and resamples between the USB microphone, the
UAC2 gadget, and the Maono interface. All are 48 kHz, but their clocks are
independent; do not force a bit-perfect path or disable resampling. A 48 kHz
graph (`default.clock.rate`) keeps the DSP hop at 48 kHz and avoids an extra
conversion.

Optional low-latency tuning in
`~/.config/pipewire/pipewire.conf.d/99-nearmic.conf`:

```conf
context.properties = {
    default.clock.rate = 48000
    default.clock.quantum = 256
    default.clock.min-quantum = 64
    default.clock.max-quantum = 1024
}
```

Start at 256 or 512; if `pw-top` shows xruns, raise the quantum. NearMic's DSP
hop is 256 samples (about 5.3 ms), so 256 is a natural graph quantum on a
healthy RK3399.

## 6. systemd design

### System gadget service

`nearmic-gadget.service`:

- `Type=oneshot`, `RemainAfterExit=yes`
- `DefaultDependencies=no`, after `local-fs.target` and
  `sys-kernel-config.mount`
- `Before=pipewire.service pipewire-pulse.service wireplumber.service
  user@1000.service`
- `ExecStart=/usr/local/sbin/nearmic-gadget-setup start`
- `ExecStop=/usr/local/sbin/nearmic-gadget-setup stop`
- `Restart=no`: a failure means the overlay or physical switch is wrong;
  looping would hide it

The `Before=user@1000.service` ordering covers the usual Armbian setup where
PipeWire is a per-user service. The user manager starts after the gadget is
bound, so PipeWire sees the ALSA card at startup.

### User services

`nearmic.service`:

- `After=pipewire.service wireplumber.service`
- `Restart=always`, `RestartSec=2`
- `Nice=-10`, `LimitRTPRIO=95`, `LimitMEMLOCK=infinity`
- `Environment=NEARMIC_NO_DEFAULT=1`

`nearmic-link.service`:

- `After=pipewire.service wireplumber.service nearmic.service`
- `Restart=always`, `RestartSec=2`
- runs `%h/.local/bin/nearmic-link` in the foreground

`nearmic-headphone-link.service`:

- `After=pipewire.service wireplumber.service`
- `Restart=always`, `RestartSec=2`
- runs `%h/.local/bin/nearmic-headphone-link` in the foreground
- no DSP: it is a plain stereo `pw-link` from the UAC2 capture source to the
  Maono playback sink

`loginctl enable-linger mariogk` is required for the user manager and these
units to start at boot without an SSH login. `apply-appliance.sh --apply`
enables lingering.

Restart policy after a config change:

```sh
systemctl --user restart nearmic.service nearmic-link.service nearmic-headphone-link.service
```

Do not restart `pipewire.service` unless you intend to drop all user audio.
The link services reconnect after NearMic, the Maono interface, or the gadget
restarts. Restarting the gadget unbinds and rebinds the UDC, so the host sees a
USB disconnect/reconnect and may reset the default source or sink; reselect
NearMic on the host if needed.

If `Nice=-10`/`LimitRTPRIO` are rejected, make sure the limits are installed:

- `/etc/security/limits.d/99-nearmic-limits.conf`
- `/etc/systemd/system/user@.service.d/99-nearmic-limits.conf`

Both are installed by `apply-appliance.sh --apply`.

## 7. udev and USB autosuspend

USB autosuspend on the microphone can cause periodic dropouts or a device that
disappears after idle. Prefer a per-device rule. First find the IDs:

```sh
lsusb
# Bus 001 Device 004: ID 046d:0000 Logitech, Inc. ...
```

Example `/etc/udev/rules.d/99-nearmic-usb-audio.rules` (replace VID/PID):

```udev
# Keep the NearMic source microphone powered; do not autosuspend it.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="0000", TEST=="power/control", ATTR{power/control}="on"
```

A class-wide rule is possible but affects every USB audio device. UAC1
interfaces use subclass `01`, UAC2 uses `02`:

```udev
ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:0101:*", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:0102:*", ATTR{power/control}="on"
```

Apply:

```sh
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb
cat /sys/bus/usb/devices/*/power/control   # expected: on
```

Do not run `powertop --auto-tune`; it re-enables autosuspend. Do not set
`usbcore.autosuspend=-1` globally unless you have measured the power cost.
The UAC2 gadget is a device on the board's upper port, not a board-side USB
device, so it needs no udev rule on the board.

## 8. Test plan

Run in order. Stop at the first failure and use the troubleshooting section.

### 8.1 Overlay and physical switch

```sh
ls /sys/class/udc
# fe800000.usb
tr -d '\0' < /proc/device-tree/usb@fe800000/usb@fe800000/dr_mode
# peripheral
tr -d '\0' < /proc/device-tree/usb@fe800000/usb@fe800000/maximum-speed
# high-speed
```

### 8.2 Gadget service

```sh
sudo systemctl status nearmic-gadget --no-pager
sudo journalctl -u nearmic-gadget -n 50 --no-pager
aplay -l
# card N: UAC2Gadget [UAC2_Gadget], device 0: ... playback
cat /sys/kernel/config/usb_gadget/nearmic/UDC
# fe800000.usb
```

### 8.3 Host enumeration

On the host computer:

```sh
lsusb | grep -i 1209:4e4d
# ... NearMic NearMic USB Microphone
arecord -l
# card N: UAC2Gadget [UAC2_Gadget], device 0: ... capture
```

If the host does not see it, check the OTG switch, the USB-A male data cable,
the upper port, and the host's `dmesg`.

### 8.4 Board ALSA

```sh
arecord -l     # real USB microphone + UAC2Gadget capture (stereo)
aplay -l       # UAC2Gadget playback (mono)

# 3-second test tone into the gadget, no PipeWire/NearMic involved
speaker-test -D plughw:CARD=UAC2Gadget,DEV=0 -c 1 -r 48000 -t sine -l 1
```

Record it on the host at the same time:

```sh
arecord -D plughw:CARD=UAC2Gadget,DEV=0 -f S16_LE -r 48000 -c 1 -d 3 /tmp/gadget-test.wav
aplay /tmp/gadget-test.wav
```

This proves the microphone direction before debugging PipeWire.

To prove the headphone direction at the ALSA level, play on the host into the
stereo playback device and record the board capture PCM:

```sh
# host
aplay -D plughw:CARD=UAC2Gadget,DEV=0 -f S16_LE -r 48000 -c 2 /path/to/tone.wav

# board
arecord -D plughw:CARD=UAC2Gadget,DEV=0 -f S16_LE -r 48000 -c 2 -d 3 /tmp/gadget-out.wav
```

### 8.5 PipeWire nodes and links

```sh
systemctl --user status pipewire wireplumber nearmic nearmic-link nearmic-headphone-link --no-pager
wpctl status
pw-link -o | grep '^nearmic:'
pw-link -i | grep -Ei 'uac2|fe800000'
pw-link -o | grep -Ei 'uac2|fe800000'
pw-link -i | grep -i maono
pw-link -l
nearmic status
```

Expected links:

```
nearmic:capture_MONO
  |-> <gadget-sink>:playback_MONO

<gadget-source>:capture_FL
  |-> <maono-sink>:playback_FL

<gadget-source>:capture_FR
  |-> <maono-sink>:playback_FR
```

There must be no link from the Maono capture ports or the NearMic DSP source
into the Maono sink. The optional `nearmic-listen` monitor stream is disabled
with `listen=false` and may appear as an idle, suspended link; it is not part of
the passthrough route.

### 8.6 Headphone passthrough

On the host, select the NearMic/UAC2 playback device as the computer output:

```sh
pactl list short sinks | grep -i near
pactl set-default-sink <near-mic-uac2-sink>
```

Play a known tone on the host (1 kHz, 5 s):

```sh
ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=5" -ac 2 /tmp/tone.wav
paplay --device=<near-mic-uac2-sink> /tmp/tone.wav
```

While it plays, record the board's gadget capture source through PipeWire:

```sh
# board
pw-record --target <gadget-source-node> --rate 48000 --channels 2 \
  --format s16 /tmp/headphone-test.wav
```

Copy the recording to the workstation and confirm the tone:

```sh
ffmpeg -i /tmp/headphone-test.wav -af "astats=metadata=1:reset=0" -f null -
# or
ffmpeg -i /tmp/headphone-test.wav -af volumedetect -f null -
```

Pass criteria: the recording has both channels at roughly the expected level
and a dominant 1 kHz component. The Maono analog output itself cannot be
captured; the link and the samples on the gadget capture source are the
observable proof. The headphones connected to the Maono interface should also
play the tone.

### 8.7 End-to-end host recording

Speak into the USB microphone, record on the host:

```sh
arecord -D plughw:CARD=UAC2Gadget,DEV=0 -f S16_LE -r 48000 -c 1 -d 10 \
  /tmp/nearmic-live.wav
aplay /tmp/nearmic-live.wav
```

Pass criteria: intelligible speech, no periodic gaps, no feedback howl, and
the level is steady. Compare with NearMic `mode bypass` to hear the processed
difference:

```sh
nearmic mode bypass
# record again
nearmic mode suppress
```

### 8.8 Recovery

```sh
# unplug/replug the USB microphone, then check the nearMic service recovered
systemctl --user status nearmic nearmic-link nearmic-headphone-link --no-pager

# restart the gadget and confirm both link services relink
sudo systemctl restart nearmic-gadget
systemctl --user status nearmic-link nearmic-headphone-link --no-pager
pw-link -l
```

### 8.9 24/7 soak

Run for at least 24 hours and check:

```sh
systemctl --user show -p NRestarts nearmic nearmic-link nearmic-headphone-link
journalctl --user -u nearmic -u nearmic-link -u nearmic-headphone-link --since '24 hours ago' | tail -100
pw-top          # xruns, quantum, sample rate
systemctl show -p RuntimeWatchdogUSec
systemctl list-timers 'apt-daily*'
```

A restart during the 04:00 unattended-upgrade reboot window is expected. A
restart loop outside that window is a bug; inspect the journal.

## 9. Troubleshooting

### `/sys/class/udc` is empty

1. Physical OTG slide switch under the board: set to **OTG/Device**.
2. `/boot/overlay-user/nearmic-otg.dtbo` exists.
3. `/boot/armbianEnv.txt` has `user_overlays=nearmic-otg` (append, do not
   replace other overlays).
4. Reboot; the overlay is applied by U-Boot.
5. `dmesg | grep -i dwc3` and
   `tr -d '\0' < /proc/device-tree/usb@fe800000/usb@fe800000/dr_mode`.

### Gadget service fails

```sh
sudo journalctl -u nearmic-gadget -n 80 --no-pager
sudo dmesg | tail -50
cat /sys/kernel/config/usb_gadget/nearmic/UDC 2>/dev/null
```

- "no USB device controller": overlay/switch/reboot.
- `write ... UDC: Device or resource busy`: another gadget is bound. Inspect
  `/sys/kernel/config/usb_gadget/*/UDC`; unbind the stale one or reboot.
- `usb_f_uac2 is unavailable`: check `CONFIG_USB_CONFIGFS_F_UAC2=y` and
  `modprobe usb_f_uac2`.
- `mkdir functions/uac2.usb0` fails: configfs not mounted or UAC2 function
  missing.

### Host does not see `1209:4e4d`

- Use the **upper** USB 3.0 Type-A port and a data cable (not charge-only).
- Confirm the OTG switch is in Device position.
- Keep USB-C power connected.
- On the host: `dmesg | tail -50`, `lsusb -d 1209:4e4d`.
- Try a different host port/cable; some USB-A-to-USB-A cables are power-only.

### Host sees the device but has no microphone

- Host `arecord -l` should show a **capture** device. If it shows only
  playback, `p_chmask`/`c_chmask` are inverted; set `p_chmask=1`,
  `c_chmask=3`, and recreate the gadget.
- Board `aplay -l` must show `UAC2Gadget` playback.
- Test with `speaker-test -D plughw:CARD=UAC2Gadget,DEV=0 ...` before
  blaming PipeWire.
- Check the link: `pw-link -l | grep -A2 nearmic`.

### Host has no speaker or headphone passthrough is silent

- Host `aplay -l` should show a NearMic/UAC2 playback device. If only capture
  is present, `c_chmask` is `0`; set `c_chmask=3`, `c_srate=48000`,
  `c_ssize=2`, and restart `nearmic-gadget.service`.
- Board `arecord -l` must show `UAC2Gadget` capture.
- Check the links:

  ```sh
  systemctl --user status nearmic-headphone-link --no-pager
  journalctl --user -u nearmic-headphone-link -n 100 --no-pager
  pw-link -o | grep -Ei 'uac2|fe800000'   # capture_FL/FR
  pw-link -i | grep -i maono              # playback_FL/FR
  pw-link -l
  ```

- Select the NearMic/UAC2 sink as the host output; the host may have reset its
  default sink after a gadget rebind.
- The Maono interface must be present on a host USB port; without it the script
  waits and the unit restarts every few seconds.

### Board does not create the UAC2Gadget card

```sh
dmesg | grep -i -E 'uac2|g_audio|configfs'
aplay -l
arecord -l
ls /sys/kernel/config/usb_gadget/nearmic/functions/uac2.usb0/
```

Verify `p_chmask=1`, `p_srate=48000`, `p_ssize=2`, `c_chmask=3`,
`c_srate=48000`, `c_ssize=2`, and that the function is linked into
`configs/c.1/uac2.usb0`.

### No NearMic source

```sh
systemctl --user status nearmic --no-pager
journalctl --user -u nearmic -n 100 --no-pager
nearmic doctor
nearmic status
```

- `pipewire_library=missing`: rebuild with the gnu target (see AGENTS.md).
- `PipeWire is not running`: start the user services; check
  `loginctl show-user mariogk -p Linger`.
- No default source and `source=""`: set `source` to the USB microphone's
  `node.name`, then restart `nearmic.service`.
- `NEARMIC_NO_DEFAULT=1` is intentional; it prevents NearMic from becoming the
  default source and accidentally capturing itself.

### Link service fails or link is missing

```sh
journalctl --user -u nearmic-link -n 100 --no-pager
pw-link -o
pw-link -i
pw-cli ls Node | grep -E 'node.name|media.class'
```

The sink node name is platform-derived. Set `NEARMIC_SINK` to the exact
`node.name` in `nearmic-link.service` if auto-detection picks nothing. Do not
link to `monitor_*` or `capture_*`.

For the headphone direction, `nearmic-headphone-link.service` auto-detects the
UAC2 capture source (`api.alsa.card.name`/`node.name`/`object.path` containing
`UAC2Gadget` or `fe800000`) and the Maono sink (`maono`/`prostudio`). Override
with `NEARMIC_HEADPHONE_SOURCE`/`NEARMIC_HEADPHONE_SINK` in a drop-in if
needed:

```sh
systemctl --user edit nearmic-headphone-link.service
# [Service]
# Environment=NEARMIC_HEADPHONE_SINK=alsa_output.usb-...analog-stereo
```

### Feedback or howling

- `listen = false` in `~/.config/nearmic/config.toml`.
- Do not select NearMic as its own capture source. Set `source` explicitly to
  the USB microphone.
- Do not link `UAC2Gadget:monitor_*` anywhere.
- Do not link the Maono capture ports or the `nearmic` source to the Maono
  playback sink; only the UAC2 gadget capture source feeds it.
- On the host, do not monitor the UAC2 microphone to the host speakers while
  the microphone is in the same room.

### Dropouts, xruns, or periodic silence

- Check USB autosuspend (`/sys/bus/usb/devices/*/power/control`).
- Use a good cable and a host port that does not share a hub with storage.
- Check `pw-top` for xruns; raise the PipeWire quantum to 512 or 1024.
- Check CPU: `nearmic status` shows `underruns`; `top`/`htop` for load.
- Keep the `rock-pi-plus` profile. The appliance pins `threads=1` and
  `cpu_budget=0.80` for RNNoise; the ASRC servo and `out_fill` already absorb
  the USB clock difference. See [QUALITY.md](QUALITY.md).
- Avoid `powertop --auto-tune` and USB autosuspend on the microphone.

### Watchdog reboots

```sh
journalctl -b -1 --no-pager | tail -100
systemctl show -p RuntimeWatchdogUSec
cat /sys/class/watchdog/watchdog0/identity
```

`RuntimeWatchdogSec=15s` is deliberate. If the board reboots under a long
uninterruptible task, identify the task; do not disable the watchdog silently.
A 15 s failure is a real hang on this appliance.

### Reboot at 04:00

`unattended-upgrades` reboots after applying upgrades. This is the maintenance
window. The host sees the microphone disconnect. If that is unacceptable,
change `Unattended-Upgrade::Automatic-Reboot-Time` in
`/etc/apt/apt.conf.d/50unattended-upgrades` as an operator decision.

## 10. 24/7 policy summary

- Ethernet only. Do not change the HomeLab router.
- `loginctl enable-linger mariogk`; user PipeWire/WirePlumber/NearMic start at
  boot.
- NearMic and the link supervisor restart automatically; the gadget does not
  restart in a loop because its failures are configuration/overlay errors.
- systemd hardware watchdog pets `/dev/watchdog0` every 15 s.
- Daily apt update and unattended full upgrade; unused dependencies removed;
  reboot at 04:00.
- `needrestart` restarts services after library upgrades; NearMic and the link
  service recover.
- No secrets in repo files. Never put an SSH key or router password in a
  tracked file.

## 11. Related files

- [`../AGENTS.md`](../AGENTS.md) — project/agent contract and safety rules
- [`SETUP.md`](SETUP.md) — file-to-destination map and installer usage
- [`README.md`](README.md) — board image, network and hardware findings
- [`scripts/setup-uac2-gadget.sh`](scripts/setup-uac2-gadget.sh)
- [`scripts/nearmic-link.sh`](scripts/nearmic-link.sh)
- [`scripts/nearmic-headphone-link.sh`](scripts/nearmic-headphone-link.sh)
- [`scripts/apply-appliance.sh`](scripts/apply-appliance.sh)
