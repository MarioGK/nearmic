#!/bin/sh
# Pass host computer playback through to the Maono headphone/output jacks.
#
#   UAC2 gadget capture source (ALSA "UAC2Gadget", capture_FL/FR)
#       -> Maono playback sink (alsa_output.usb-Maono_..., playback_FL/FR)
#
# The UAC2 gadget is a stereo speaker on the host computer and a capture PCM on
# the board: USB-OUT -> ALSA_Capture.  This script links that capture source
# straight to the real USB audio interface's playback ports.  There is no
# resampling stage of our own and no DSP; PipeWire schedules and, if needed,
# resamples between the gadget and the Maono interface.
#
# It never links the Maono capture ports or the NearMic source to the Maono
# sink, so the processed voice cannot loop back into the headphones.
#
# The script stays in the foreground and supervises the links.  If either node
# disappears (gadget re-enumerated, microphone unplugged, PipeWire restart) it
# exits non-zero and the systemd user unit restarts it after RestartSec.
#
# Environment:
#   NEARMIC_HEADPHONE_SOURCE       UAC2 capture source node.name (default: auto)
#   NEARMIC_HEADPHONE_SINK         Maono playback sink node.name (default: auto)
#   NEARMIC_HEADPHONE_TIMEOUT      seconds to wait for both nodes (default: 120)
#   NEARMIC_HEADPHONE_INTERVAL     seconds between link checks (default: 5)
set -eu
LC_ALL=C

SOURCE="${NEARMIC_HEADPHONE_SOURCE:-}"
SINK="${NEARMIC_HEADPHONE_SINK:-}"
TIMEOUT="${NEARMIC_HEADPHONE_TIMEOUT:-120}"
INTERVAL="${NEARMIC_HEADPHONE_INTERVAL:-5}"
LINKED=""

log() { printf 'nearmic-headphone: %s\n' "$*" >&2; }

output_ports() {
	pw-link -o 2>/dev/null |
		awk -v n="$1" 'index($0, n ":") == 1 { print substr($0, length(n) + 2) }'
}

input_ports() {
	pw-link -i 2>/dev/null |
		awk -v n="$1" 'index($0, n ":") == 1 { print substr($0, length(n) + 2) }'
}

# Print the node.name of the first node matching media.class and pattern.
# Reads PipeWire's JSON dump so it can match api.alsa.card.name, which the
# plain `pw-cli ls Node` output does not show.  card/name/description/path are
# all checked: on this board the gadget card is "UAC2_Gadget" and the node
# names are platform-derived ("alsa_input.platform-fe800000.usb...").
find_node() {
	local class="$1" pattern="$2"
	pw-dump 2>/dev/null | python3 -c '
import json, re, sys

kind, pattern = sys.argv[1], re.compile(sys.argv[2], re.I)
try:
    objects = json.load(sys.stdin)
except Exception:
    sys.exit(1)

for obj in objects:
    if obj.get("type") != "PipeWire:Interface:Node":
        continue
    props = (obj.get("info") or {}).get("props") or {}
    if props.get("media.class") != kind:
        continue
    fields = (
        props.get("api.alsa.card.name"),
        props.get("alsa.card_name"),
        props.get("node.name"),
        props.get("node.description"),
        props.get("object.path"),
    )
    if any(f and pattern.search(str(f)) for f in fields):
        print(props.get("node.name", ""))
        break
' "$class" "$pattern"
}

find_source() {
	[ -n "$SOURCE" ] && return 0
	local candidate
	candidate="$(find_node "Audio/Source" "uac2|fe800000" || true)"
	[ -n "$candidate" ] || return 1
	SOURCE="$candidate"
	return 0
}

find_sink() {
	[ -n "$SINK" ] && return 0
	local candidate
	candidate="$(find_node "Audio/Sink" "maono|prostudio" || true)"
	[ -n "$candidate" ] || return 1
	SINK="$candidate"
	return 0
}

# Pick the output port for one channel.  ALSA sources expose capture_FL/FR;
# accept other prefixes but never a monitor port.
pick_output_port() {
	local channel="$1"
	output_ports "$SOURCE" |
		grep -E '(^|_)'"$channel"'$' |
		grep -v '^monitor' |
		sed -n '1p'
}

pick_input_port() {
	local channel="$1"
	input_ports "$SINK" |
		grep -E '(^|_)'"$channel"'$' |
		sed -n '1p'
}

link_exists() {
	pw-link -l 2>/dev/null | awk -v a="${SOURCE}:$1" -v b="${SINK}:$2" '
		/^[^[:space:]]/ { src = $0; next }
		/^[[:space:]]+\|-> / {
			dst = $0
			sub(/^[[:space:]]+\|-> /, "", dst)
			if (src == a && dst == b) found = 1
		}
		END { exit found ? 0 : 1 }
	'
}

cleanup_links() {
	[ -n "${LINKED:-}" ] || return 0
	for pair in $LINKED; do
		src="${pair%%|*}"
		dst="${pair#*|}"
		pw-link -d "${SOURCE}:${src}" "${SINK}:${dst}" >/dev/null 2>&1 || true
	done
	LINKED=""
}

make_links() {
	[ -n "$SOURCE" ] && [ -n "$SINK" ] || return 1

	src_ports="$(output_ports "$SOURCE")"
	sink_ports="$(input_ports "$SINK")"
	if [ -z "$src_ports" ] || [ -z "$sink_ports" ]; then
		return 1
	fi

	LINKED=""
	for channel in FL FR; do
		src="$(pick_output_port "$channel")"
		dst="$(pick_input_port "$channel")"
		[ -n "$src" ] && [ -n "$dst" ] || continue

		# Adopt links that are already correct; only create the missing ones.
		LINKED="${LINKED}${LINKED:+ }${src}|${dst}"
		if link_exists "$src" "$dst"; then
			continue
		fi

		log "link ${SOURCE}:${src} -> ${SINK}:${dst}"
		if ! pw-link "${SOURCE}:${src}" "${SINK}:${dst}"; then
			log "pw-link failed for ${src} -> ${dst}"
			return 1
		fi
	done

	[ -n "$LINKED" ] || return 1
	return 0
}

ready() {
	output_ports "$SOURCE" | grep -q . || return 1
	find_sink || return 1
	input_ports "$SINK" | grep -q . || return 1
	return 0
}

# Resolve the source lazily: it only exists after the gadget is bound and
# WirePlumber has created the ALSA source node.
wait_for_nodes() {
	waited=0
	noticed=0
	while :; do
		find_source || true
		if ready; then
			return 0
		fi
		if [ "$noticed" -eq 0 ]; then
			log "waiting for UAC2 gadget capture source and Maono playback sink"
			noticed=1
		fi
		if [ "$waited" -ge "$TIMEOUT" ]; then
			log "timed out after ${TIMEOUT}s"
			log "output ports:"
			pw-link -o 2>/dev/null | sed 's/^/  /' >&2 || true
			log "input ports:"
			pw-link -i 2>/dev/null | sed 's/^/  /' >&2 || true
			log "hint: systemctl --user status pipewire wireplumber"
			log "hint: pw-dump | grep -E 'node.name|media.class|alsa.card.name'"
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
}

trap 'cleanup_links' EXIT
trap 'log "stopping"; exit 0' INT TERM

wait_for_nodes || exit 1

log "source ${SOURCE} ports: $(output_ports "$SOURCE" | tr '\n' ' ')"
log "sink ${SINK} ports: $(input_ports "$SINK" | tr '\n' ' ')"

make_links || exit 1

while :; do
	sleep "$INTERVAL"
	if ! output_ports "$SOURCE" | grep -q . || ! input_ports "$SINK" | grep -q .; then
		log "source or sink disappeared; exiting for systemd restart"
		exit 1
	fi
	if ! make_links; then
		log "could not restore links; exiting for systemd restart"
		exit 1
	fi
done
