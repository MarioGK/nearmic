#!/bin/sh
set -eu
ROOT=${HUSHMIC_NATIVE:-/tmp/hushmic/crates/hushmic-denoiser/native}
OUT=${DPDF_OUT:-/tmp/dpdf-build}
rm -rf "$OUT"
mkdir -p "$OUT"

base_c() {
    gcc -O3 -DNDEBUG -fno-lto -ffp-contract=off -fvisibility=hidden -std=gnu11 \
        -I"$ROOT/include" -I"$ROOT/src" -I"$ROOT/src/private" "$@"
}

compile_one() {
    src=$1
    obj=$2
    shift 2
    mkdir -p "$(dirname "$obj")"
    base_c "$@" -c "$src" -o "$obj"
}

build_model() {
    size=$1
    name=$2
    objdir=$OUT/$name
    ns=$ROOT/src/private/namespace${size}.h
    defs="-include $ns -DDPDF_MODEL_SIZE=$size -DDPDF_X86_DISPATCH -DDPDF_QASM64 -DDPDF_QFUSED64 -DDPDF_QPAIR_FIXED -DDPDF_HAS_AVX_VNNI"
    if [ "$size" = 2 ]; then
        defs="$defs -DDPDF_QFUSED256 -DDPDF_QPAIR_FUSED64"
    fi
    for src in full_ops.c dpdf_dprnn.c extended_ops.c; do
        compile_one "$ROOT/src/common/$src" "$objdir/$src.o" $defs
    done
    compile_one "$ROOT/src/model_backend.c" "$objdir/model_backend.c.o" $defs
    compile_one "$ROOT/src/models/$name/generated_model.c" "$objdir/generated_model.c.o" $defs
    for src in avx2.c int8.c; do
        compile_one "$ROOT/src/common/$src" "$objdir/$src.o" $defs -mavx2 -mfma
    done
    compile_one "$ROOT/src/common/fp16.c" "$objdir/fp16.c.o" $defs -mavx2 -mfma -mf16c
    compile_one "$ROOT/src/common/int8_vnni.c" "$objdir/int8_vnni.c.o" $defs -mavx2 -mfma -mavxvnni
    for src in qdot64_fixed_avx2.S qdot4pair_fixed_avx2.S qdot64_fixed_vnni.S qdot4pair_fixed_vnni.S; do
        compile_one "$ROOT/src/common/$src" "$objdir/$src.o" $defs
    done
    for src in qaffine64_fused_avx2.S qaffine64_fused_vnni.S; do
        compile_one "$ROOT/src/models/$name/$src" "$objdir/$src.o" $defs
    done
    if [ "$size" = 2 ]; then
        for src in qaffine256_fused_avx2.S qaffine256_fused_vnni.S qaffine4pair64_fused_avx2.S qaffine4pair64_fused_vnni.S; do
            compile_one "$ROOT/src/models/$name/$src" "$objdir/$src.o" $defs
        done
    fi
}

build_model 8 dpdfnet8_48khz_hr
build_model 2 dpdfnet2_48khz_hr
compile_one "$ROOT/src/runtime.c" "$OUT/runtime.c.o"
ar rcs "$OUT/libdpdfnet.a" "$OUT"/*/*.o "$OUT/runtime.c.o"
mkdir -p "$OUT/include"
cp "$ROOT/include/dpdfnet.h" "$OUT/include/dpdfnet.h"
echo "built $OUT/libdpdfnet.a"
