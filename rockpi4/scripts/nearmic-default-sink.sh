#!/bin/sh
# Make the UAC2 gadget the board's default sink, so WirePlumber auto-connects
# the NearMic source to the computer microphone path instead of the Maono
# headphone/playback sink.  Best effort: the link service also sets it.
set -eu

SINK="${NEARMIC_GADGET_SINK:-alsa_output.platform-fe800000.usb.mono-fallback}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

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
