#!/usr/bin/env bash
# Cross-compile RNNoise for the ROCK 4 Plus and stage it for
#   zig build -Dbundle=true
#
# It creates third_party/rnnoise/{librnnoise.a,include/rnnoise.h}.
# The repository ignores third_party/ because the archive is large.
set -euo pipefail

ZIG="${ZIG:-zig}"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RNNOISE_SRC="${RNNOISE_SRC:-/tmp/rnnoise}"
OUT="$REPO/third_party/rnnoise"
OBJ="${RNNOISE_OBJ:-/tmp/rnnoise-arm}"
TARGET="${RNNOISE_TARGET:-aarch64-linux-gnu}"
CPU="${RNNOISE_CPU:-cortex_a53}"

if [ ! -d "$RNNOISE_SRC" ]; then
	git clone --depth 1 https://github.com/xiph/rnnoise "$RNNOISE_SRC"
fi
if [ ! -f "$RNNOISE_SRC/src/rnnoise_data.c" ]; then
	(cd "$RNNOISE_SRC" && ./autogen.sh && ./configure)
fi

mkdir -p "$OBJ" "$OUT/include"
for f in denoise rnn pitch kiss_fft celt_lpc nnet nnet_default \
	parse_lpcnet_weights rnnoise_data rnnoise_tables; do
	"$ZIG" cc -target "$TARGET" -mcpu="$CPU" -O3 -fPIC \
		-I"$RNNOISE_SRC/include" -I"$RNNOISE_SRC/src" \
		-c "$RNNOISE_SRC/src/$f.c" -o "$OBJ/$f.o"
done
"$ZIG" ar rcs "$OUT/librnnoise.a" "$OBJ"/*.o
cp "$RNNOISE_SRC/include/rnnoise.h" "$OUT/include/"

echo "staged $OUT/librnnoise.a"
echo "now: zig build -Dtarget=$TARGET -Dcpu=$CPU -Doptimize=ReleaseFast -Dbundle=true"
