#!/usr/bin/env bash
# Install the NearMic 24/7 USB microphone appliance configuration.
#
# Default is a dry run.  Pass --apply to copy files, install missing packages,
# enable the gadget/units and start the user PipeWire/NearMic services.
#
#   sudo ./apply-appliance.sh                          # show what would change
#   sudo ./apply-appliance.sh --apply                  # apply, no reboot
#   sudo ./apply-appliance.sh --apply --reboot         # apply, then reboot
#   sudo ./apply-appliance.sh --apply --skip-packages
#
# Without --reboot this script never reboots.  The dwc3 OTG overlay needs a
# reboot before /sys/class/udc becomes populated; --reboot performs it in one
# step so the board converges without a second interactive round trip.
set -euo pipefail

APPLY=0
SKIP_PACKAGES=0
REBOOT=0
for arg in "$@"; do
	case "$arg" in
	--apply) APPLY=1 ;;
	--skip-packages) SKIP_PACKAGES=1 ;;
	--reboot) REBOOT=1 ;;
	-h | --help)
		sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'unknown argument: %s\n' "$arg" >&2
		exit 2
		;;
	esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd -- "$SCRIPT_DIR/.." && pwd)" # rockpi4/
BOARD_USER="${NEARMIC_USER:-mariogk}"
BOARD_HOME="$(getent passwd "$BOARD_USER" | cut -d: -f6 || true)"
BOARD_UID="$(id -u "$BOARD_USER" 2>/dev/null || true)"
BOARD_GID="$(id -g "$BOARD_USER" 2>/dev/null || true)"
ARMBIAN_ENV="/boot/armbianEnv.txt"
OVERLAY_NAME="nearmic-otg"
OVERLAY_DST="/boot/overlay-user/${OVERLAY_NAME}.dtbo"

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ -n "$BOARD_HOME" ] || die "user ${BOARD_USER} does not exist (set NEARMIC_USER)"
[ -n "$BOARD_UID" ] || die "cannot resolve uid for ${BOARD_USER}"

if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
	die "--apply needs root (sudo)"
fi

if [ "$REBOOT" -eq 1 ] && [ "$APPLY" -ne 1 ]; then
	die "--reboot needs --apply (a dry run never reboots)"
fi

say "NearMic appliance installer"
say "  source: $SRC"
say "  user:   $BOARD_USER ($BOARD_UID), home $BOARD_HOME"
say "  mode:   $([ "$APPLY" -eq 1 ] && echo apply || echo 'dry run (use --apply)')$([ "$REBOOT" -eq 1 ] && echo ' + reboot')"

do_install() {
	local src="$1" dst="$2" mode="$3" owner="${4:-root:root}"
	[ -e "$src" ] || die "missing source file: $src"
	if [ "$APPLY" -eq 1 ]; then
		# Create parent directories with the destination owner.  Without this,
		# user config files such as ~/.config/nearmic/config.toml would be
		# created under a root-owned directory and the user could not edit them.
		install -d -m 0755 -o "${owner%%:*}" -g "${owner##*:}" "$(dirname -- "$dst")"
		install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst"
		say "  installed $dst"
	else
		say "  would install $src -> $dst ($mode $owner)"
	fi
}

run() {
	if [ "$APPLY" -eq 1 ]; then
		"$@"
	else
		printf '  would run:'
		printf ' %q' "$@"
		printf '\n'
	fi
}

run_as_user() {
	run runuser -u "$BOARD_USER" -- env \
		HOME="$BOARD_HOME" \
		XDG_RUNTIME_DIR="/run/user/$BOARD_UID" \
		"$@"
}

# ---------------------------------------------------------------- packages
REQUIRED_PACKAGES=(pipewire wireplumber pipewire-audio alsa-utils unattended-upgrades needrestart)
missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
	if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
		missing+=("$pkg")
	fi
done

if [ "${#missing[@]}" -gt 0 ]; then
	if [ "$SKIP_PACKAGES" -eq 1 ]; then
		warn "missing packages (skipped): ${missing[*]}"
	else
		say "Missing packages: ${missing[*]}"
		if [ "$APPLY" -eq 1 ]; then
			DEBIAN_FRONTEND=noninteractive apt-get update
			DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
		else
			say "  would run: apt-get update && apt-get install -y ${missing[*]}"
		fi
	fi
fi

# ----------------------------------------------------------------- overlay
DTS="$SRC/dtb/${OVERLAY_NAME}.dts"
DTBO="$SRC/dtb/${OVERLAY_NAME}.dtbo"
if [ ! -f "$DTBO" ]; then
	if [ "$APPLY" -eq 1 ] && command -v dtc >/dev/null 2>&1; then
		dtc -@ -I dts -O dtb -o "$DTBO" "$DTS"
	else
		die "missing $DTBO (install dtc and compile $DTS)"
	fi
fi

say "USB OTG overlay:"
do_install "$DTBO" "$OVERLAY_DST" 0644 root:root

ensure_armbian_overlay() {
	[ -f "$ARMBIAN_ENV" ] || die "missing $ARMBIAN_ENV"
	local current new
	current="$(sed -n "s/^user_overlays=//p" "$ARMBIAN_ENV" | tail -n 1)"
	case " $current " in
	*" $OVERLAY_NAME "*)
		say "  $ARMBIAN_ENV already lists $OVERLAY_NAME"
		return 0
		;;
	esac

	new="${current:+$current }$OVERLAY_NAME"
	if [ "$APPLY" -eq 1 ]; then
		[ -e "${ARMBIAN_ENV}.nearmic.bak" ] || cp -a "$ARMBIAN_ENV" "${ARMBIAN_ENV}.nearmic.bak"
		if grep -q '^user_overlays=' "$ARMBIAN_ENV"; then
			sed -i "s|^user_overlays=.*|user_overlays=${new}|" "$ARMBIAN_ENV"
		else
			printf 'user_overlays=%s\n' "$new" >>"$ARMBIAN_ENV"
		fi
		say "  updated $ARMBIAN_ENV: user_overlays=${new}"
	else
		say "  would set user_overlays=${new} in $ARMBIAN_ENV"
	fi
}
ensure_armbian_overlay

# Kernel command line. rt_group_sched=0: the Armbian kernel is built with
# CONFIG_RT_GROUP_SCHED, which with cgroup v2 refuses SCHED_FIFO to every
# process outside the root cgroup, i.e. to PipeWire and NearMic ("SCHED_FIFO
# not granted (PERM)"). Without realtime priority the audio graph missed about
# four cycles a second and the microphone sounded robotic (2026-11-11).
ensure_extraarg() {
	local arg="$1" current
	current="$(sed -n 's/^extraargs=//p' "$ARMBIAN_ENV" | tail -n 1)"
	case " $current " in *" $arg "*) say "  $ARMBIAN_ENV extraargs already has $arg"; return 0 ;; esac
	if [ "$APPLY" -eq 1 ]; then
		if grep -q '^extraargs=' "$ARMBIAN_ENV"; then
			sed -i "s|^extraargs=.*|extraargs=${current:+$current }$arg|" "$ARMBIAN_ENV"
		else
			printf 'extraargs=%s\n' "$arg" >>"$ARMBIAN_ENV"
		fi
		say "  added $arg to extraargs (takes effect after a reboot)"
	else
		say "  would add $arg to extraargs in $ARMBIAN_ENV"
	fi
}
ensure_extraarg rt_group_sched=0

# User-owned directory skeleton.  `install -D` below would otherwise create
# ~/.local and ~/.config/systemd as root, and WirePlumber then cannot write
# ~/.local/state (seen 2026-11-11: "wp-state: Permission denied").
if [ "$APPLY" -eq 1 ]; then
	install -d -m 0755 -o "$BOARD_USER" -g "$BOARD_GID" \
		"$BOARD_HOME/.local" "$BOARD_HOME/.local/bin" "$BOARD_HOME/.local/state" \
		"$BOARD_HOME/.config" "$BOARD_HOME/.config/systemd" "$BOARD_HOME/.config/systemd/user" \
		"$BOARD_HOME/.config/nearmic"
fi

# ---------------------------------------------------------------- binaries
BIN_SRC="${NEARMIC_BINARY:-$SRC/../zig-out/bin/nearmic}"
if [ -s "$BIN_SRC" ]; then
	do_install "$BIN_SRC" "$BOARD_HOME/.local/bin/nearmic" 0755 "$BOARD_USER:$BOARD_GID"
else
	warn "NearMic binary not found at $BIN_SRC; copy zig-out/bin/nearmic to $BOARD_HOME/.local/bin/nearmic"
fi

do_install "$SRC/scripts/setup-uac2-gadget.sh" /usr/local/sbin/nearmic-gadget-setup 0755 root:root
do_install "$SRC/scripts/nearmic-wifi-watchdog.sh" /usr/local/sbin/nearmic-wifi-watchdog 0755 root:root
do_install "$SRC/scripts/nearmic-uboot-guard.py" /usr/local/sbin/nearmic-uboot-guard 0755 root:root
do_install "$SRC/scripts/nearmic-udc-watch.py" /usr/local/sbin/nearmic-udc-watch 0755 root:root
do_install "$SRC/systemd/nearmic-udc-watch.service" /etc/systemd/system/nearmic-udc-watch.service 0644 root:root
do_install "$SRC/systemd/nearmic-uboot-guard.service" /etc/systemd/system/nearmic-uboot-guard.service 0644 root:root
do_install "$SRC/apt/99nearmic-uboot-guard" /etc/apt/apt.conf.d/99nearmic-uboot-guard 0644 root:root
do_install "$SRC/scripts/nearmic-link.sh" "$BOARD_HOME/.local/bin/nearmic-link" 0755 "$BOARD_USER:$BOARD_GID"
do_install "$SRC/scripts/nearmic-default-sink.sh" "$BOARD_HOME/.local/bin/nearmic-default-sink" 0755 "$BOARD_USER:$BOARD_GID"
do_install "$SRC/scripts/nearmic-headphone-link.sh" "$BOARD_HOME/.local/bin/nearmic-headphone-link" 0755 "$BOARD_USER:$BOARD_GID"
do_install "$SRC/scripts/nearmic-health.sh" "$BOARD_HOME/.local/bin/nearmic-health" 0755 "$BOARD_USER:$BOARD_GID"

# --------------------------------------------------------------- nearMic cfg
CONFIG_DST="$BOARD_HOME/.config/nearmic/config.toml"
if [ -e "$CONFIG_DST" ]; then
	say "  keeping existing $CONFIG_DST"
else
	do_install "$SRC/config/nearmic-config.toml" "$CONFIG_DST" 0644 "$BOARD_USER:$BOARD_GID"
fi

# ------------------------------------------------------------------- units
do_install "$SRC/systemd/nearmic-gadget.service" /etc/systemd/system/nearmic-gadget.service 0644 root:root
do_install "$SRC/systemd/nearmic-cpufreq.service" /etc/systemd/system/nearmic-cpufreq.service 0644 root:root
do_install "$SRC/systemd/nearmic-wifi-watchdog.service" /etc/systemd/system/nearmic-wifi-watchdog.service 0644 root:root
do_install "$SRC/systemd/nearmic-wifi-watchdog.timer" /etc/systemd/system/nearmic-wifi-watchdog.timer 0644 root:root
do_install "$SRC/systemd/nearmic-dash.service" /etc/systemd/system/nearmic-dash.service 0644 root:root
do_install "$SRC/dash/nearmic-dash.py" /usr/local/share/nearmic/dash/nearmic-dash.py 0755 root:root
do_install "$SRC/dash/index.html" /usr/local/share/nearmic/dash/index.html 0644 root:root
do_install "$SRC/systemd/nearmic.service" "$BOARD_HOME/.config/systemd/user/nearmic.service" 0644 "$BOARD_USER:$BOARD_GID"
do_install "$SRC/systemd/nearmic-link.service" "$BOARD_HOME/.config/systemd/user/nearmic-link.service" 0644 "$BOARD_USER:$BOARD_GID"
do_install "$SRC/systemd/nearmic-headphone-link.service" "$BOARD_HOME/.config/systemd/user/nearmic-headphone-link.service" 0644 "$BOARD_USER:$BOARD_GID"
do_install "$SRC/systemd/nearmic-health.service" "$BOARD_HOME/.config/systemd/user/nearmic-health.service" 0644 "$BOARD_USER:$BOARD_GID"
do_install "$SRC/systemd/nearmic-health.timer" "$BOARD_HOME/.config/systemd/user/nearmic-health.timer" 0644 "$BOARD_USER:$BOARD_GID"

# ------------------------------------------------------- pipewire/wireplumber
# System drop-in: keep the UAC2 gadget and the Maono interface streaming (no
# suspend-on-idle) and shrink the ALSA periods so the host's first sample is
# not behind 340 ms of stale buffer.  See the file for the latency budget.
do_install "$SRC/wireplumber/51-nearmic-latency.conf" \
	/etc/wireplumber/wireplumber.conf.d/51-nearmic-latency.conf 0644 root:root

# ----------------------------------------------------------------- apt/system
do_install "$SRC/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades 0644 root:root
do_install "$SRC/apt/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades 0644 root:root
do_install "$SRC/apt/needrestart.conf" /etc/needrestart/conf.d/99-nearmic.conf 0644 root:root
do_install "$SRC/systemd/watchdog.conf" /etc/systemd/system.conf.d/99-nearmic-watchdog.conf 0644 root:root
for unit in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
	do_install "$SRC/systemd/apt-background.conf" "/etc/systemd/system/${unit}.d/99-nearmic-background.conf" 0644 root:root
done
do_install "$SRC/config/99-nearmic-limits.conf" /etc/security/limits.d/99-nearmic-limits.conf 0644 root:root
do_install "$SRC/config/99-nearmic-sysctl.conf" /etc/sysctl.d/99-nearmic.conf 0644 root:root
do_install "$SRC/config/cpufrequtils" /etc/default/cpufrequtils 0644 root:root
# Network files: USB Wi-Fi is always wlan0, power save off, and the USB
# maintenance link (192.168.77.1) of the gadget's NCM function.
do_install "$SRC/network/10-nearmic-usb-wifi.link" /etc/systemd/network/10-nearmic-usb-wifi.link 0644 root:root
do_install "$SRC/network/30-nearmic-usb0.network" /etc/systemd/network/30-nearmic-usb0.network 0644 root:root
do_install "$SRC/udev/70-nearmic-wifi.rules" /etc/udev/rules.d/70-nearmic-wifi.rules 0644 root:root
do_install "$SRC/systemd/wlan0-device.d/10-nearmic-timeout.conf" \
	"/etc/systemd/system/sys-subsystem-net-devices-wlan0.device.d/10-nearmic-timeout.conf" 0644 root:root
do_install "$SRC/systemd/user@.service.d/99-nearmic-limits.conf" \
	"/etc/systemd/system/user@.service.d/99-nearmic-limits.conf" 0644 root:root

do_install "$SRC/AUDIO.md" /usr/local/share/doc/nearmic/AUDIO.md 0644 root:root
do_install "$SRC/SETUP.md" /usr/local/share/doc/nearmic/SETUP.md 0644 root:root

# ------------------------------------------------------------------ enable
say "Enabling services:"
run systemctl daemon-reload
if systemctl list-unit-files apt-daily.timer apt-daily-upgrade.timer 2>/dev/null | grep -q '^apt-daily'; then
	run systemctl enable apt-daily.timer apt-daily-upgrade.timer
else
	warn "apt-daily timers are not installed; install unattended-upgrades first"
fi
run systemctl enable nearmic-gadget.service
run systemctl enable nearmic-cpufreq.service || warn "could not enable nearmic-cpufreq.service"
run systemctl restart nearmic-cpufreq.service || warn "could not start nearmic-cpufreq.service"
run systemctl enable --now nearmic-wifi-watchdog.timer || warn "could not start nearmic-wifi-watchdog.timer"
run systemctl enable nearmic-uboot-guard.service || warn "could not enable nearmic-uboot-guard.service"
run systemctl enable nearmic-udc-watch.service || warn "could not enable nearmic-udc-watch.service"
run systemctl restart nearmic-udc-watch.service || warn "could not start nearmic-udc-watch.service"
run /usr/local/sbin/nearmic-uboot-guard || warn "U-Boot boot-order guard reported a problem"
run systemctl enable nearmic-dash.service || warn "could not enable nearmic-dash.service"
run systemctl restart nearmic-dash.service || warn "could not start nearmic-dash.service"
run sysctl -q -p /etc/sysctl.d/99-nearmic.conf || warn "could not apply the panic-reboot sysctl"

if [ -n "$(ls -A /sys/class/udc 2>/dev/null || true)" ]; then
	run systemctl restart nearmic-gadget.service || warn "gadget failed to start; check the OTG switch and overlay"
else
	warn "no UDC yet: reboot required for the ${OVERLAY_NAME} overlay (and check the OTG/Device switch); gadget service is enabled but not started"
fi

run loginctl enable-linger "$BOARD_USER"
run systemctl start "user@${BOARD_UID}.service" || warn "could not start user@${BOARD_UID}.service"
run_as_user systemctl --user daemon-reload || warn "user systemd daemon-reload failed"
run_as_user systemctl --user enable --now pipewire.socket pipewire.service wireplumber.service ||
	warn "could not enable user PipeWire/WirePlumber units"

if [ -x "$BOARD_HOME/.local/bin/nearmic" ] || [ "$APPLY" -eq 0 ]; then
	run_as_user systemctl --user enable nearmic.service nearmic-link.service nearmic-headphone-link.service ||
		warn "could not enable nearmic/nearmic-link/nearmic-headphone-link user units"
	run_as_user systemctl --user restart nearmic.service nearmic-link.service nearmic-headphone-link.service ||
		warn "could not start nearmic/nearmic-link/nearmic-headphone-link user units"
	run_as_user systemctl --user enable --now nearmic-health.timer ||
		warn "could not enable nearmic-health.timer"
else
	warn "NearMic binary missing; not starting nearmic.service"
fi

say ""
say "Watchdog and PAM/systemd limit changes take effect on the next user session"
say "or reboot.  The OTG overlay needs a reboot before 'ls /sys/class/udc' can"
say "show fe800000.usb."
say ""
say "Verify after reboot:"
say "  ls /sys/class/udc"
say "  cat /proc/device-tree/usb@fe800000/usb@fe800000/dr_mode | tr -d '\\0'"
say "  systemctl status nearmic-gadget"
say "  systemctl --user status nearmic nearmic-link nearmic-headphone-link"
say "  pw-link -l"

if [ "$REBOOT" -eq 1 ]; then
	say ""
	say "Rebooting now as requested by --reboot.  The host sees the microphone"
	say "disconnect until the board is back and the gadget has re-enumerated."
	sync
	# --no-block so this script is not killed by the reboot it triggered.
	systemctl reboot --no-block || die "could not trigger reboot"
fi
