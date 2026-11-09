#!/bin/sh
# NearMic PipeWire defaults, run from nearmic.service ExecStartPre.
#
# 1. Make the UAC2 gadget the board's default sink, so WirePlumber
#    auto-connects the NearMic source to the computer microphone path instead
#    of the Maono headphone/playback sink. Best effort: the link service also
#    sets it.
# 2. Force the graph quantum to 128 frames (2.7 ms). The stock 1024 is 21 ms
#    of extra latency on the microphone, and the NearMic ring plus the UAC2
#    ALSA periods are sized around the smaller quantum. The value lives in
#    PipeWire metadata, so it has to be re-applied after every PipeWire start;
#    nearmic-health also restores it every minute.
set -eu

SINK="${NEARMIC_GADGET_SINK:-alsa_output.platform-fe800000.usb.mono-fallback}"
QUANTUM="${NEARMIC_QUANTUM:-128}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

if command -v pw-metadata >/dev/null 2>&1; then
	pw-metadata -n settings 0 clock.force-quantum "$QUANTUM" >/dev/null 2>&1 || true
fi

i=0
while [ "$i" -lt 30 ]; do
	sid="$(pw-cli ls Node 2>/dev/null | awk -v n="$SINK" '
		/^[[:space:]]*id [0-9]+,/ { id=$2; sub(/,.*/, "", id) }
		index($0, "node.name = \"" n "\"") { print id; exit }
	')"
	if [ -n "$sid" ] && wpctl set-default "$sid" >/dev/null 2>&1; then
		exit 0
	fi
	i=$((i + 1))
	sleep 1
done
exit 0
