#!/bin/sh
# Keep the USB Wi-Fi link alive without anyone logging in.
#
# Runs every minute from nearmic-wifi-watchdog.timer (root).  It never reboots
# the board: audio does not need the network, so a Wi-Fi outage must not cost
# the microphone.  Escalation while the gateway stays unreachable:
#   2 min  restart wpa_supplicant for wlan0 and ask networkd to reconfigure
#   5 min  netplan apply (regenerates and restarts the whole Wi-Fi stack)
#   10 min logically replug the USB adapter (deauthorize/authorize), start over
# It also renames a USB Wi-Fi interface that missed the wlan0 .link rename and
# switches Wi-Fi power save off, which otherwise drops idle links.
set -u

IFACE=wlan0
STATE=/run/nearmic-wifi-fail
log() { logger -t nearmic-wifi "$*" 2>/dev/null || echo "nearmic-wifi: $*"; }

if [ ! -e "/sys/class/net/$IFACE" ]; then
	for d in /sys/class/net/*; do
		[ -e "$d/phy80211" ] || continue
		other="$(basename "$d")"
		log "renaming $other to $IFACE"
		ip link set dev "$other" down 2>/dev/null
		ip link set dev "$other" name "$IFACE" 2>/dev/null && break
	done
fi
# No adapter plugged in: nothing to repair.
[ -e "/sys/class/net/$IFACE" ] || { rm -f "$STATE"; exit 0; }

iw dev "$IFACE" set power_save off 2>/dev/null

gw="$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')"
if [ -n "$gw" ] && ping -c 1 -W 3 -I "$IFACE" "$gw" >/dev/null 2>&1; then
	rm -f "$STATE"
	exit 0
fi
# One lost ping is not an outage.
if [ -n "$gw" ] && ping -c 2 -W 3 -I "$IFACE" "$gw" >/dev/null 2>&1; then
	rm -f "$STATE"
	exit 0
fi

n=$(($(cat "$STATE" 2>/dev/null || echo 0) + 1))
echo "$n" >"$STATE"
case "$n" in
2)
	log "no gateway for 2 min: restarting wpa_supplicant on $IFACE"
	rfkill unblock wifi 2>/dev/null
	systemctl restart "netplan-wpa-$IFACE.service" 2>/dev/null
	networkctl reconfigure "$IFACE" 2>/dev/null
	;;
5)
	log "no gateway for 5 min: netplan apply"
	netplan apply 2>/dev/null
	;;
10)
	log "no gateway for 10 min: replugging the USB adapter"
	dev="$(readlink -f "/sys/class/net/$IFACE/device")"
	# device is the USB interface; its parent is the USB device.
	usb="$(dirname "$dev")"
	if [ -w "$usb/authorized" ]; then
		echo 0 >"$usb/authorized"
		sleep 3
		echo 1 >"$usb/authorized"
	fi
	rm -f "$STATE"
	;;
esac
exit 0
