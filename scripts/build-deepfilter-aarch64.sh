#!/usr/bin/env bash
# Cross-compile DeepFilterNet3 (libDF C API + tract) for the ROCK 4 Plus and
# stage it for
#   zig build -Dbundle=true
#
# It creates third_party/deepfilter/libdf.a with the DeepFilterNet3 model
# embedded (no model file on the board). scripts/patches/
# deepfilternet-nearmic.patch adds:
#   - a parallel ERB decoder thread (the DF decoder runs on the caller), which
#     cuts per-frame time on the RK3399 A72 pair from ~7.0 ms to ~4.8 ms with
#     bit-identical output; DF_THREADS=1 turns it off,
#   - df_create(NULL, ...) loading the embedded model,
#   - DF_PROF=1 per-stage timings on stderr.
#
# Needs: rustup, cargo-zigbuild (cargo install cargo-zigbuild), zig 0.14.1.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${DF_SRC:-$HOME/.local/share/nearmic-tools/DeepFilterNet}"
# Upstream main at the time of the port; the patch applies to this commit.
REV="${DF_REV:-7b14b895fe7fc42cab72b4a4c1e49c982bd6404b}"
OUT="$REPO/third_party/deepfilter"
TRIPLE="aarch64-unknown-linux-gnu"

if [ ! -d "$SRC/.git" ]; then
	git clone https://github.com/Rikorose/DeepFilterNet.git "$SRC"
fi
cd "$SRC"
git checkout -q "$REV"
if ! git diff --quiet -- libDF; then
	echo "$SRC/libDF has local changes; resetting before applying the patch"
	git checkout -q -- libDF
fi
git apply "$REPO/scripts/patches/deepfilternet-nearmic.patch"

rustup target add "$TRIPLE" >/dev/null
# The A72 pair runs the model (the unit pins NearMic there); cortex-a72
# code still runs on the A53s.
CARGO_PROFILE_RELEASE_LTO=true \
	CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
	RUSTFLAGS="-C target-cpu=cortex-a72" \
	cargo zigbuild --release --target "$TRIPLE.2.36" \
	-p deep_filter --lib --no-default-features --features capi

mkdir -p "$OUT"
cp "target/$TRIPLE/release/libdf.a" "$OUT/libdf.a"
git checkout -q -- libDF

echo "staged $OUT/libdf.a"
echo "now: zig build -Dtarget=aarch64-linux-gnu -Dcpu=cortex_a53 -Doptimize=ReleaseFast -Dbundle=true"
