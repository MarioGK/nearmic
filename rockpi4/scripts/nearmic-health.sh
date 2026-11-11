#!/bin/sh
# nearmic-health: one-shot 24/7 self check for the NearMic appliance.
#
# Run by nearmic-health.timer every minute (user systemd). It does not touch
# the DSP; it only repairs the plumbing that a USB replug, a USB re-enumeration
# or a PipeWire restart can break:
#
#   - the UAC2 gadget system service and its UDC, including a USB link that
#     did not re-enumerate after the computer woke up
#   - the three user units (nearmic, both link supervisors)
#   - the NearMic source actually streaming (an active unit can be stalled)
#   - the UAC2 gadget as the WirePlumber default sink
#   - the low-latency graph quantum
#
# It is deliberately quiet: it logs only when it repairs something, so a
# healthy board writes nothing to the journal.
set -u

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
HOME="${HOME:-/home/$(id -un)}"
BIN="$HOME/.local/bin/nearmic"
GADGET="${NEARMIC_UDC:-fe800000.usb}"
SINK="${NEARMIC_GADGET_SINK:-alsa_output.platform-fe800000.usb.mono-fallback}"
QUANTUM="${NEARMIC_QUANTUM:-128}"

log() { echo "nearmic-health: $*"; }

# Without the overlay/UDC there is no gadget to repair; restarting units would
# only hide that, and the gadget unit itself refuses to start. A reboot is the
# only fix, and the operator has to schedule it.
[ -e "/sys/class/udc/$GADGET" ] || exit 0

# 0. The USB link to the computer. After the computer suspends and resumes,
#    dwc3 can stay in "default"/"addressed": bus reset seen, never enumerated,
#    so the computer has no NearMic device until something re-attaches it
#    (seen 2026-11-11: gone from 15:49 until a manual re-attach at 18:04).
#    If the link is in such a half-open state on two checks in a row, pulse
#    the pull-up. "configured" is healthy; "suspended"/"not attached" mean the
#    computer is asleep or unplugged and need nothing.
UDC_STATE="$(cat "/sys/class/udc/$GADGET/state" 2>/dev/null || true)"
UDC_FLAG="$XDG_RUNTIME_DIR/nearmic-udc-halfopen"
case "$UDC_STATE" in
default | addressed | powered | attached)
	if [ -e "$UDC_FLAG" ]; then
		log "USB link stuck in '$UDC_STATE'; re-attaching to the computer"
		echo disconnect | sudo -n tee "/sys/class/udc/$GADGET/soft_connect" >/dev/null 2>&1
		sleep 1
		echo connect | sudo -n tee "/sys/class/udc/$GADGET/soft_connect" >/dev/null 2>&1
		rm -f "$UDC_FLAG"
	else
		: >"$UDC_FLAG"
	fi
	;;
*) rm -f "$UDC_FLAG" ;;
esac

# 1. System gadget unit. It is a oneshot with RemainAfterExit=yes, so it stays
#    "active" unless it failed; a failed start after re-enumeration is the case
#    the link units cannot repair on their own.
if ! systemctl is-active --quiet nearmic-gadget; then
	log "restarting nearmic-gadget"
	sudo -n systemctl restart nearmic-gadget >/dev/null 2>&1 || log "gadget restart failed (reboot may be required)"
	sleep 2
fi

# 2. User units. The link supervisors exit on purpose when a node disappears
#    and systemd restarts them; this catches the case where they gave up.
for unit in nearmic nearmic-link nearmic-headphone-link; do
	if ! systemctl --user is-active --quiet "$unit"; then
		log "restarting $unit"
		systemctl --user restart "$unit" >/dev/null 2>&1 || log "could not restart $unit"
	fi
done

# 3. "active" is not the same as "streaming": if the source stream stalled the
#    unit still looks healthy while the host gets nothing but silence.
if [ -x "$BIN" ]; then
	streaming="$("$BIN" status 2>/dev/null | sed -n 's/^streaming=//p')"
	if [ "${streaming:-1}" = "0" ]; then
		log "source is not streaming; restarting nearmic"
		systemctl --user restart nearmic >/dev/null 2>&1 || log "could not restart nearmic"
	fi
fi

# 4. The gadget must stay the default sink. Otherwise WirePlumber would link
#    the processed voice to the Maono headphones and the host would get
#    nothing. The helper is idempotent and silent if it works.
if [ -x "$HOME/.local/bin/nearmic-default-sink" ]; then
	"$HOME/.local/bin/nearmic-default-sink" >/dev/null 2>&1 || true
fi

# 5. The low-latency quantum lives in PipeWire metadata, which is lost when
#    PipeWire restarts. Restore it without restarting anything.
if command -v pw-metadata >/dev/null 2>&1; then
	current="$(pw-metadata -n settings 2>/dev/null | sed -n "s/.*key:'clock.force-quantum' value:'\([0-9]*\)'.*/\1/p" | head -n1)"
	if [ "$current" != "$QUANTUM" ]; then
		pw-metadata -n settings 0 clock.force-quantum "$QUANTUM" >/dev/null 2>&1 &&
			log "restored clock.force-quantum=$QUANTUM"
	fi
fi

# 6. Both fixed routes. pw-link is idempotent and cheap; recreate the link
#    only when a port exists and the link does not.
if command -v pw-link >/dev/null 2>&1; then
	if pw-link -o 2>/dev/null | grep -qx 'nearmic:capture_MONO' &&
		pw-link -i 2>/dev/null | grep -qx "$SINK:playback_MONO" &&
		! pw-link -l 2>/dev/null | grep -A1 '^nearmic:capture_MONO$' | grep -qx "  |-$SINK:playback_MONO"; then
		pw-link 'nearmic:capture_MONO' "$SINK:playback_MONO" >/dev/null 2>&1 &&
			log "restored nearmic -> gadget link"
	fi

	maono="$(pw-link -i 2>/dev/null | sed -n 's/^\(alsa_output\.usb-Maono[^:]*\):playback_FL$/\1/p' | head -n1)"
	if [ -n "$maono" ] &&
		! pw-link -l 2>/dev/null | grep -A2 '^alsa_input\.platform-fe800000\.usb\.stereo-fallback:capture_FL$' | grep -qx "  |-> $maono:playback_FL"; then
		pw-link 'alsa_input.platform-fe800000.usb.stereo-fallback:capture_FL' "$maono:playback_FL" >/dev/null 2>&1 &&
			pw-link 'alsa_input.platform-fe800000.usb.stereo-fallback:capture_FR' "$maono:playback_FR" >/dev/null 2>&1 &&
			log "restored gadget -> Maono passthrough"
	fi
fi

# 7. The Maono headphone amp squeals when the passthrough is broken. The link
#    supervisor mutes the interface before it exits; once the route is real
#    again, undo that mute here too, so a supervisor restart or a boot where
#    the gadget came up late cannot leave the headphones silent forever.
FLAG="$XDG_RUNTIME_DIR/nearmic-maono-muted"
if [ -e "$FLAG" ] && command -v wpctl >/dev/null 2>&1; then
	maono="$(pw-link -i 2>/dev/null | sed -n 's/^\(alsa_output\.usb-Maono[^:]*\):playback_FL$/\1/p' | head -n1)"
	if [ -n "$maono" ] &&
		pw-link -l 2>/dev/null | grep -A2 '^alsa_input\.platform-fe800000\.usb\.stereo-fallback:capture_FL$' | grep -qx "  |-> $maono:playback_FL"; then
		id="$(pw-cli ls Node 2>/dev/null | awk -v n="$maono" '
			/^[[:space:]]*id [0-9]+,/ { id=$2; sub(/,.*/, "", id) }
			index($0, "node.name = \"" n "\"") { print id; exit }
		')"
		if [ -n "$id" ]; then
			wpctl set-mute "$id" 0 >/dev/null 2>&1 && rm -f "$FLAG" && log "restored Maono output"
		fi
	fi
fi

# 8. The gadget sink is the microphone the host records. WirePlumber restored
#    this node at volume 0.46 once, which made the whole microphone quiet even
#    though the DSP was at full level. The appliance path is unity.
if command -v wpctl >/dev/null 2>&1; then
	id="$(pw-cli ls Node 2>/dev/null | awk -v n="$SINK" '
		/^[[:space:]]*id [0-9]+,/ { id=$2; sub(/,.*/, "", id) }
		index($0, "node.name = \"" n "\"") { print id; exit }
	')"
	if [ -n "$id" ]; then
		wpctl set-mute "$id" 0 >/dev/null 2>&1 || true
		wpctl set-volume "$id" 1.0 >/dev/null 2>&1 || true
	fi
fi

exit 0
