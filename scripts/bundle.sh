#!/bin/sh
# Stage RNNoise, native DPDFNet, FFTW, and the gcc cpu-dispatch object under
# third_party/ so `zig build -Dbundle=true` can link them. Existing /tmp
# artifacts are copied when they are already built. Nothing here is committed.
set -eu
cd "$(dirname "$0")/.."
TP=third_party
mkdir -p "$TP/models" "$TP/rnnoise/include" "$TP/dpdfnet/include" "$TP/fftw"

if [ ! -f "$TP/rnnoise/librnnoise.a" ]; then
  if [ -f /tmp/librnnoise.a ] && [ -f /tmp/rnnoise/include/rnnoise.h ]; then
    cp /tmp/librnnoise.a "$TP/rnnoise/librnnoise.a"
    cp /tmp/rnnoise/include/rnnoise.h "$TP/rnnoise/include/rnnoise.h"
  else
    rm -rf "$TP/rnnoise-src"
    git clone https://github.com/xiph/rnnoise.git "$TP/rnnoise-src"
    git -C "$TP/rnnoise-src" checkout 70f1d256acd4b34a572f999a05c87bf00b67730d
    (
      cd "$TP/rnnoise-src"
      if [ -f download_model.sh ]; then sh download_model.sh; fi
      ./autogen.sh
      ./configure --disable-shared --enable-static CFLAGS="-O3 -mavx2 -mfma"
      make -j"$(nproc)"
    )
    lib=$(find "$TP/rnnoise-src" -name 'librnnoise.a' | head -n 1)
    cp "$lib" "$TP/rnnoise/librnnoise.a"
    cp "$TP/rnnoise-src/include/rnnoise.h" "$TP/rnnoise/include/rnnoise.h"
  fi
fi

if [ ! -f "$TP/dpdfnet/libdpdfnet.a" ]; then
  if [ -f /tmp/dpdf-build/libdpdfnet.a ] && [ -f /tmp/hushmic/crates/hushmic-denoiser/native/include/dpdfnet.h ]; then
    cp /tmp/dpdf-build/libdpdfnet.a "$TP/dpdfnet/libdpdfnet.a"
    cp /tmp/hushmic/crates/hushmic-denoiser/native/include/dpdfnet.h "$TP/dpdfnet/include/dpdfnet.h"
  else
    rm -rf "$TP/hushmic"
    git clone --filter=blob:none https://github.com/Fovty/hushmic.git "$TP/hushmic"
    git -C "$TP/hushmic" checkout da61fd45821effb4f8600f24bd3c4e1776c92f19
    HUSHMIC_NATIVE="$TP/hushmic/crates/hushmic-denoiser/native" DPDF_OUT="$TP/dpdfnet" sh scripts/ai/build_dpdfnet.sh
  fi
fi

if [ ! -f "$TP/dpdfnet/cpuinfo.o" ]; then
  tmp=$(mktemp -d)
  (cd "$tmp" && ar x "$(gcc -print-file-name=libgcc.a)" cpuinfo.o)
  mv "$tmp/cpuinfo.o" "$TP/dpdfnet/cpuinfo.o"
  rm -rf "$tmp"
fi

if [ ! -f "$TP/fftw/libfftw3f.a" ]; then
  if [ -f /usr/lib/x86_64-linux-gnu/libfftw3f.a ]; then
    cp /usr/lib/x86_64-linux-gnu/libfftw3f.a "$TP/fftw/libfftw3f.a"
  elif [ -f /usr/lib/libfftw3f.a ]; then
    cp /usr/lib/libfftw3f.a "$TP/fftw/libfftw3f.a"
  else
    echo "libfftw3f.a is not installed (apt install libfftw3-dev)" >&2
    exit 1
  fi
fi

fetch_w() {
  name=$1
  sha=$2
  dest="$TP/models/${name}.weights.f32"
  if [ -f "$dest" ] && echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
    return 0
  fi
  local_src="/tmp/hushmic/assets/models/${name}.weights.f32"
  urls="
https://raw.githubusercontent.com/ceva-ip/DPDFNet/afa8292f3b8083c3daadd06dbcfe4ff877dd3172/optimized_inference/models/${name}/weights.f32
https://github.com/Fovty/hushmic/releases/download/v0.10.0/${name}.weights.f32
"
  if [ -f "$local_src" ]; then
    cp "$local_src" "$dest.dl"
    if echo "$sha  $dest.dl" | sha256sum -c - >/dev/null 2>&1; then
      mv "$dest.dl" "$dest"
      return 0
    fi
    rm -f "$dest.dl"
  fi
  for url in $urls; do
    rm -f "$dest.dl"
    if curl -fsSL "$url" -o "$dest.dl" && echo "$sha  $dest.dl" | sha256sum -c - >/dev/null 2>&1; then
      mv "$dest.dl" "$dest"
      return 0
    fi
    echo "ignored $url" >&2
  done
  echo "failed to fetch $name weights" >&2
  exit 1
}

fetch_w dpdfnet8_48khz_hr 5a5bb67a8619090c54dc2793536fe813fe38123b236d445f3433aafe3075529d
fetch_w dpdfnet2_48khz_hr cb7248b8fccbff7b32f254ec2ed0061e604514b2ccd98d997cd081a876424e7b
echo "bundle staged in $TP"
