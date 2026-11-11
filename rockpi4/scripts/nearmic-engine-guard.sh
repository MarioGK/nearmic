#!/usr/bin/env bash
# First-boot safety net: time the configured DeepFilterNet engine on this
# board and fall back to RNNoise if it cannot run comfortably in realtime.
#
# It processes a 10 s speech clip on the A72 pair (where nearmic.service
# runs). DeepFilterNet must finish in under 85 % of the clip duration (see
# LIMIT below); otherwise config.toml is
# switched to engine = "rnnoise", gain_db = 10 and the reason is logged.
set -euo pipefail

USER_NAME="${NEARMIC_USER:-mariogk}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
CFG="$HOME_DIR/.config/nearmic/config.toml"
BIN="$HOME_DIR/.local/bin/nearmic"
CLIP="${NEARMIC_GUARD_CLIP:-/opt/nearmic/bin/guard-clip.wav}"
# The clip run includes about 1.3 s of model start-up, so 10 s of audio takes
# about 7 s on this board (0.69-0.73) while the per-frame cost is 5.4 ms of
# each 10 ms. Live it ran with 0 underruns (2026-11-11). 0.85 still catches a
# board that cannot keep up.
LIMIT="${NEARMIC_GUARD_LIMIT:-0.85}"

log() { echo "nearmic-engine-guard: $*"; }

grep -q '^engine = "deepfilter"' "$CFG" 2>/dev/null || { log "engine is not deepfilter; nothing to check"; exit 0; }
[ -x "$BIN" ] && [ -f "$CLIP" ] || { log "binary or clip missing; leaving config as is"; exit 0; }

fallback() {
	log "falling back to RNNoise: $1"
	sed -i 's/^engine = .*/engine = "rnnoise"/; s/^gain_db = .*/gain_db = 10/' "$CFG"
}

dur=$(python3 -c "import wave,sys; w=wave.open(sys.argv[1]); print(w.getnframes()/w.getframerate())" "$CLIP")
start=$(date +%s.%N)
if ! out=$(runuser -u "$USER_NAME" -- env HOME="$HOME_DIR" taskset -c 4,5 "$BIN" enhance "$CLIP" /tmp/nearmic-guard.wav 2>&1); then
	fallback "enhance failed: $out"
	exit 0
fi
end=$(date +%s.%N)
rm -f /tmp/nearmic-guard.wav
case "$out" in *"engine deepfilter"*) ;; *) fallback "engine did not open: $out"; exit 0 ;; esac
ratio=$(python3 -c "import sys; print(f'{(float(sys.argv[2])-float(sys.argv[1]))/float(sys.argv[3]):.3f}')" "$start" "$end" "$dur")
if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)" "$ratio" "$LIMIT"; then
	log "deepfilter realtime factor $ratio (limit $LIMIT): keeping it"
else
	fallback "realtime factor $ratio is above $LIMIT"
fi
