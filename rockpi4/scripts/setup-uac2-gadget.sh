#!/bin/sh
# NearMic UAC2 USB audio gadget (configfs), duplex.
#
# Board side view: two ALSA PCMs on the UAC2Gadget card.
#   - playback: the board writes PCM, the gadget sends it to the host (USB-IN)
#   - capture:  the host sends PCM, the board reads it (USB-OUT)
# Host side view: a USB microphone (mono capture) plus a stereo speaker.
#
# Direction (from the kernel f_uac2 topology):
#   ALSA_Playback -> USB-IN -> host capture   (p_chmask, the NearMic microphone)
#   USB-OUT -> ALSA_Capture -> board capture  (c_chmask, headphone passthrough)
#
# Usage:
#   setup-uac2-gadget.sh start   # default
#   setup-uac2-gadget.sh stop    # unbind and remove the gadget
#   setup-uac2-gadget.sh check   # verify the UDC / overlay state
#
# The RK3399 dwc3 controller for the upper USB 3.0 Type-A port is OTG0
# (fe800000.usb).  Armbian's stock DTB sets it to host mode, so this script
# refuses to run until the NearMic overlay has switched it to peripheral.
set -eu

GADGET_NAME="${NEARMIC_GADGET_NAME:-nearmic}"
GADGET_DIR="/sys/kernel/config/usb_gadget/${GADGET_NAME}"
CONFIGFS_DIR="/sys/kernel/config"

VID="${NEARMIC_VID:-0x1209}"       # pid.codes open-source vendor ID
PID="${NEARMIC_PID:-0x4e4d}"       # private/demo product ID ("NM")
SERIAL="${NEARMIC_SERIAL:-NEARMIC-0001}"
MANUFACTURER="${NEARMIC_MANUFACTURER:-NearMic}"
# The computer builds its device names from this: "NearMic Mono" (input) and
# "NearMic Analog Stereo" (output), instead of an output called "Microphone".
PRODUCT="${NEARMIC_PRODUCT:-NearMic}"
MAX_POWER="${NEARMIC_MAX_POWER:-500}" # mA; the board itself is on the USB-C PSU

WANT_ACM=1
WANT_NCM=1

log() { printf 'nearmic-gadget: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
	cat >&2 <<'EOF'
usage: setup-uac2-gadget.sh [start|stop|check]

start   create, configure and bind the duplex UAC2 gadget (default)
stop    unbind the gadget and remove its configfs objects
check   report the UDC and overlay state without changing anything
EOF
}

mount_configfs() {
	if grep -qs " ${CONFIGFS_DIR} configfs " /proc/mounts; then
		return 0
	fi
	mkdir -p "$CONFIGFS_DIR"
	mount -t configfs none "$CONFIGFS_DIR" ||
		die "could not mount configfs on ${CONFIGFS_DIR}"
}

load_modules() {
	# Built-in on the Armbian 6.18 kernel, but harmless when modular.
	modprobe libcomposite 2>/dev/null || true
	modprobe usb_f_uac2 2>/dev/null || true
	modprobe usb_f_acm 2>/dev/null || true
	modprobe usb_f_ncm 2>/dev/null || true
}

dr_mode() {
	local path="/proc/device-tree/usb@fe800000/usb@fe800000/dr_mode"
	if [ -r "$path" ]; then
		tr -d '\000' <"$path"
	fi
}

find_udc() {
	[ -d /sys/class/udc ] || return 1

	# Prefer OTG0 explicitly; there is only one gadget-capable controller.
	if [ -d /sys/class/udc/fe800000.usb ]; then
		printf '%s\n' "fe800000.usb"
		return 0
	fi

	local udc
	for udc in /sys/class/udc/*; do
		[ -d "$udc" ] || continue
		basename "$udc"
		return 0
	done

	return 1
}

missing_udc_message() {
	local mode
	mode="$(dr_mode 2>/dev/null || true)"
	cat >&2 <<EOF
nearmic-gadget: ERROR: no USB device controller in /sys/class/udc.
nearmic-gadget: dwc3 dr_mode is '${mode:-unknown}'.

The stock Armbian DTB puts both RK3399 dwc3 controllers in host mode.
Install the NearMic overlay and reboot before starting this service:

  sudo install -D -m 0644 rockpi4/dtb/nearmic-otg.dtbo /boot/overlay-user/nearmic-otg.dtbo
  # add: user_overlays=nearmic-otg  to /boot/armbianEnv.txt
  sudo reboot

Also check the physical OTG slide switch on the underside of the board,
below the USB ports.  It must be set to OTG/Device, not Host.

After the reboot, 'ls /sys/class/udc' must show fe800000.usb and
/proc/device-tree/usb@fe800000/usb@fe800000/dr_mode must read 'peripheral'
with maximum-speed 'high-speed'.
EOF
}

cleanup_gadget() {
	[ -d "$GADGET_DIR" ] || return 0

	# Unbind first.  Writing an empty string releases the UDC.
	if [ -e "$GADGET_DIR/UDC" ] && [ -s "$GADGET_DIR/UDC" ]; then
		printf '\n' >"$GADGET_DIR/UDC" 2>/dev/null || true
	fi

	rm -f "$GADGET_DIR/configs/c.1/uac2.usb0" 2>/dev/null || true
	rm -f "$GADGET_DIR/configs/c.1/acm.usb0" 2>/dev/null || true
	rm -f "$GADGET_DIR/configs/c.1/ncm.usb0" 2>/dev/null || true
	rmdir "$GADGET_DIR/functions/uac2.usb0" 2>/dev/null || true
	rmdir "$GADGET_DIR/functions/acm.usb0" 2>/dev/null || true
	rmdir "$GADGET_DIR/functions/ncm.usb0" 2>/dev/null || true
	rmdir "$GADGET_DIR/configs/c.1/strings/0x409" 2>/dev/null || true
	rmdir "$GADGET_DIR/configs/c.1" 2>/dev/null || true
	rmdir "$GADGET_DIR/strings/0x409" 2>/dev/null || true
	rmdir "$GADGET_DIR" 2>/dev/null || true
}

configure_gadget() {
	mkdir -p "$GADGET_DIR"

	printf '%s\n' "$VID" >"$GADGET_DIR/idVendor"
	printf '%s\n' "$PID" >"$GADGET_DIR/idProduct"
	printf '%s\n' "0x0200" >"$GADGET_DIR/bcdUSB"
	printf '%s\n' "0x0100" >"$GADGET_DIR/bcdDevice"

	mkdir -p "$GADGET_DIR/strings/0x409"
	printf '%s\n' "$SERIAL" >"$GADGET_DIR/strings/0x409/serialnumber"
	printf '%s\n' "$MANUFACTURER" >"$GADGET_DIR/strings/0x409/manufacturer"
	printf '%s\n' "$PRODUCT" >"$GADGET_DIR/strings/0x409/product"

	mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
	printf '%s\n' "$MAX_POWER" >"$GADGET_DIR/configs/c.1/MaxPower"
	printf '%s\n' "UAC2 duplex audio" >"$GADGET_DIR/configs/c.1/strings/0x409/configuration"

	mkdir -p "$GADGET_DIR/functions/uac2.usb0"
	# p_* is the ALSA playback -> USB-IN path: the host records this as its
	# microphone.  Mono, 48 kHz, S16_LE.
	printf '%s\n' "1" >"$GADGET_DIR/functions/uac2.usb0/p_chmask"
	printf '%s\n' "48000" >"$GADGET_DIR/functions/uac2.usb0/p_srate"
	printf '%s\n' "2" >"$GADGET_DIR/functions/uac2.usb0/p_ssize"
	# c_* is the USB-OUT -> ALSA capture path: the host plays to this as its
	# speaker, and the board reads the samples from the UAC2Gadget capture PCM.
	# Stereo, 48 kHz, S16_LE (the host gets a stereo playback device).
	printf '%s\n' "3" >"$GADGET_DIR/functions/uac2.usb0/c_chmask"
	printf '%s\n' "48000" >"$GADGET_DIR/functions/uac2.usb0/c_srate"
	printf '%s\n' "2" >"$GADGET_DIR/functions/uac2.usb0/c_ssize"

	ln -sfn "$GADGET_DIR/functions/uac2.usb0" "$GADGET_DIR/configs/c.1/uac2.usb0"

	# Optional maintenance console (CDC-ACM, NEARMIC_ACM=1). It does not fit
	# next to audio + network on this controller, so it is off by default.
	if [ "$WANT_ACM" = 1 ] && mkdir -p "$GADGET_DIR/functions/acm.usb0" 2>/dev/null; then
		ln -sfn "$GADGET_DIR/functions/acm.usb0" "$GADGET_DIR/configs/c.1/acm.usb0"
	fi
	# Maintenance network: CDC-NCM USB Ethernet. The board is 192.168.77.1
	# (usb0, systemd-networkd DHCP server), so SSH works over this cable even
	# without Wi-Fi. Fixed MACs keep the host interface name stable.
	if [ "$WANT_NCM" = 1 ] && mkdir -p "$GADGET_DIR/functions/ncm.usb0" 2>/dev/null; then
		printf '%s\n' "02:4e:4d:00:00:01" >"$GADGET_DIR/functions/ncm.usb0/dev_addr" 2>/dev/null || true
		printf '%s\n' "02:4e:4d:00:00:02" >"$GADGET_DIR/functions/ncm.usb0/host_addr" 2>/dev/null || true
		ln -sfn "$GADGET_DIR/functions/ncm.usb0" "$GADGET_DIR/configs/c.1/ncm.usb0"
	fi
}

start_gadget() {
	mount_configfs
	load_modules

	udc="$(find_udc)" || {
		missing_udc_message
		exit 1
	}

	mode="$(dr_mode 2>/dev/null || true)"
	if [ -n "$mode" ] && [ "$mode" != "peripheral" ]; then
		log "ERROR: OTG0 dr_mode is '${mode}', not 'peripheral'."
		log "Install the NearMic overlay, set the physical OTG switch to OTG/Device, and reboot."
		exit 1
	fi

	# The microphone must come up even if the controller cannot fit every
	# function (endpoint budget) or a maintenance function is missing from the
	# kernel: try audio+network+serial, then audio+network, then audio alone.
	# The serial function is off by default: on this dwc3 the UDC refuses
	# audio + network + serial together ("failed to start nearmic: -19", seen
	# 2026-11-11), and an image without this fallback exposed no USB device.
	for variant in "${NEARMIC_ACM:-0} ${NEARMIC_NCM:-1}" "0 ${NEARMIC_NCM:-1}" "0 0"; do
		WANT_ACM="${variant% *}"
		WANT_NCM="${variant#* }"
		cleanup_gadget
		configure_gadget
		[ -d "$GADGET_DIR/functions/uac2.usb0" ] ||
			die "usb_f_uac2 is unavailable; check CONFIG_USB_CONFIGFS_F_UAC2 and modprobe usb_f_uac2"
		if printf '%s\n' "$udc" 2>/dev/null >"$GADGET_DIR/UDC"; then
			log "UAC2 gadget bound to ${udc} (${VID}:${PID}, 48000 Hz S16_LE, serial=${WANT_ACM} network=${WANT_NCM})"
			log "host side: mono microphone (capture) + stereo speaker (playback)"
			log "board side: aplay -l / arecord -l (UAC2Gadget playback and capture)"
			return 0
		fi
		log "binding to ${udc} failed with serial=${WANT_ACM} network=${WANT_NCM}; trying fewer functions"
	done

	log "binding to ${udc} failed"
	log "check: dmesg | tail -n 40; cat ${GADGET_DIR}/UDC"
	exit 1
}

check_state() {
	if ! udc="$(find_udc)"; then
		missing_udc_message
		return 1
	fi
	log "UDC: ${udc}"
	log "dwc3 dr_mode: $(dr_mode 2>/dev/null || printf 'unknown')"
	if [ -d "$GADGET_DIR" ]; then
		log "gadget: present (UDC=$(cat "$GADGET_DIR/UDC" 2>/dev/null || true))"
	else
		log "gadget: not created"
	fi
}

case "${1:-start}" in
start)
	start_gadget
	;;
stop)
	cleanup_gadget
	log "stopped"
	;;
check)
	check_state
	;;
-h | --help | help)
	usage
	;;
*)
	usage
	exit 2
	;;
esac
