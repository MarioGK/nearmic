#!/bin/sh
# Connect the NearMic PipeWire source to the UAC2 gadget sink.
#
#   NearMic source (node.name "nearmic", capture_MONO, mono F32)
#       -> UAC2 gadget sink (ALSA "UAC2Gadget", playback_MONO, mono S16_LE)
#
# The gadget is a playback sink on the board and a microphone on the host
# computer: ALSA_Playback -> USB-IN.  The script never links monitor or capture
# ports back into NearMic, so there is no feedback path.
#
# The script stays in the foreground and supervises the links.  If either node
# disappears (USB microphone unplugged, gadget re-enumerated, NearMic restart)
# it exits non-zero and the systemd user unit restarts it after RestartSec.
#
# Environment:
#   NEARMIC_SOURCE        source node.name (default: nearmic)
#   NEARMIC_SINK          sink node.name (default: auto-detect UAC2Gadget)
#   NEARMIC_LINK_TIMEOUT  seconds to wait for both nodes (default: 120)
#   NEARMIC_LINK_INTERVAL seconds between link checks (default: 5)
set -eu
LC_ALL=C

SOURCE="${NEARMIC_SOURCE:-nearmic}"
SINK="${NEARMIC_SINK:-}"
TIMEOUT="${NEARMIC_LINK_TIMEOUT:-120}"
INTERVAL="${NEARMIC_LINK_INTERVAL:-5}"
LINKED=""

log() { printf 'nearmic-link: %s\n' "$*" >&2; }

output_ports() {
	pw-link -o 2>/dev/null |
		awk -v n="$1" 'index($0, n ":") == 1 { print substr($0, length(n) + 2) }'
}

input_ports() {
	pw-link -i 2>/dev/null |
		awk -v n="$1" 'index($0, n ":") == 1 { print substr($0, length(n) + 2) }'
}

set_default_sink() {
	[ -n "$SINK" ] || return 0
	command -v wpctl >/dev/null 2>&1 || return 0
	local sid
	sid="$(pw-cli ls Node 2>/dev/null | awk -v n="$SINK" '
		/^[[:space:]]*id [0-9]+,/ { id=$2; sub(/,.*/, "", id) }
		index($0, "node.name = \"" n "\"") { print id; exit }
	')"
	if [ -n "$sid" ]; then
		wpctl set-default "$sid" >/dev/null 2>&1 || true
	fi
}

# Remove any link from the NearMic source to a sink other than the UAC2 gadget.
# WirePlumber auto-connects an Audio/Source to the current default sink; if the
# default was the Maono headphone sink, that would monitor the processed voice
# in the headphones.  The gadget is the only correct destination.
prune_source_links() {
	[ -n "$SINK" ] || return 0
	pw-link -l 2>/dev/null | awk -v src="${SOURCE}:" -v keep="${SINK}:" '
		/^[^[:space:]]/ { out = $0; next }
		/^[[:space:]]+\|-> / {
			dst = $0
			sub(/^[[:space:]]+\|-> /, "", dst)
			if (index(out, src) == 1 && index(dst, keep) != 1) print out "|" dst
		}
	' | while IFS='|' read -r out dst; do
		[ -n "$out" ] && [ -n "$dst" ] || continue
		log "removing foreign link ${out} -> ${dst}"
		pw-link -d "$out" "$dst" >/dev/null 2>&1 || true
	done
}

# Find the UAC2 gadget sink.  PipeWire names the ALSA card node after the
# card/platform.  On this board it contains "UAC2Gadget" and/or "fe800000".
# Match node.name and node.description, but only for media.class Audio/Sink.
find_sink() {
	[ -n "$SINK" ] && return 0

	local candidate
	candidate="$(
		pw-cli ls Node 2>/dev/null | awk '
			/^[[:space:]]*id [0-9]+, type PipeWire:Interface:Node/ {
				if (sink && name != "") print name "\t" desc
				sink = 0; name = ""; desc = ""
				next
			}
			/media\.class = "Audio\/Sink"/ { sink = 1 }
			/node\.name = "/ {
				line = $0
				sub(/^.*node\.name = "/, "", line)
				sub(/".*$/, "", line)
				name = line
			}
			/node\.description = "/ {
				line = $0
				sub(/^.*node\.description = "/, "", line)
				sub(/".*$/, "", line)
				desc = line
			}
			END { if (sink && name != "") print name "\t" desc }
		' | grep -Ei 'uac2|nearmic|fe800000' | head -n 1 | cut -f 1
	)"

	if [ -z "$candidate" ]; then
		return 1
	fi
	SINK="$candidate"
	return 0
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
	[ -n "$SINK" ] || return 1

	src_ports="$(output_ports "$SOURCE")"
	sink_ports="$(input_ports "$SINK")"
	if [ -z "$src_ports" ] || [ -z "$sink_ports" ]; then
		return 1
	fi

	first_src="$(printf '%s\n' "$src_ports" | sed -n '1p')"
	i=0
	LINKED=""
	for dst in $sink_ports; do
		i=$((i + 1))
		src="$(printf '%s\n' "$src_ports" | sed -n "${i}p")"
		[ -n "$src" ] || src="$first_src"

		if link_exists "$src" "$dst"; then
			LINKED="${LINKED}${LINKED:+ }${src}|${dst}"
			continue
		fi

		log "link ${SOURCE}:${src} -> ${SINK}:${dst}"
		if ! pw-link -L "${SOURCE}:${src}" "${SINK}:${dst}"; then
			log "pw-link failed for ${src} -> ${dst}"
			return 1
		fi
		LINKED="${LINKED}${LINKED:+ }${src}|${dst}"
	done

	return 0
}

ready() {
	output_ports "$SOURCE" | grep -q . || return 1
	find_sink || return 1
	input_ports "$SINK" | grep -q . || return 1
	return 0
}

wait_for_nodes() {
	waited=0
	noticed=0
	while ! ready; do
		if [ "$noticed" -eq 0 ]; then
			log "waiting for PipeWire source '${SOURCE}' and UAC2 gadget sink"
			noticed=1
		fi
		if [ "$waited" -ge "$TIMEOUT" ]; then
			log "timed out after ${TIMEOUT}s"
			log "output ports:"
			pw-link -o 2>/dev/null | sed 's/^/  /' >&2 || true
			log "input ports:"
			pw-link -i 2>/dev/null | sed 's/^/  /' >&2 || true
			log "hint: systemctl --user status nearmic.service nearmic-link.service"
			log "hint: pw-cli ls Node | grep -E 'node.name|media.class'"
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	return 0
}

trap 'cleanup_links' EXIT
trap 'log "stopping"; exit 0' INT TERM

wait_for_nodes || exit 1
find_sink || exit 1
set_default_sink

log "source ${SOURCE} ports: $(output_ports "$SOURCE" | tr '\n' ' ')"
log "sink ${SINK} ports: $(input_ports "$SINK" | tr '\n' ' ')"

make_links || exit 1
prune_source_links

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
	prune_source_links
done
