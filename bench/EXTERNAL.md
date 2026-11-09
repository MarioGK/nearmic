# Candidates outside the shipped binary

The live bake-off in [RESULTS.md](RESULTS.md) measured the engines that are compiled into `nearmic-bakeoff`. `dsp-dereverb` is the only one of those that passed every gate, and it is the engine in the release binary.

RNNoise, LocalVQE, and both DPDFNet models were then run on the same fixture. The measured rows are in [AI.md](AI.md). Short version: DPDFNet is fast on this machine, and it does not pass the loudness gate unless a makeup gain is added by hand.

## RNNoise

Xiph commit `70f1d25`, current generated weights, AVX2. On this Xeon the 480-sample frame costs 0.58 ms at the 99th percentile, 1.3% of the 4 cores. The runtime is fast. After the first burst it deletes the rest of this synthetic voice, so the scored speech level is -62 dBFS and the row fails. The weight file stays out of the release binary.

## LocalVQE

[LocalVQE](https://github.com/localai-org/LocalVQE) `7f61cd0` with its GGML submodule, built as a shared library with gcc and g++. Clang could not link `libstdc++` because the unversioned linker script lives in GCC's private directory. The shared library itself built once `CXX=g++`.

v1.2 (1.3 M, 16 kHz, one thread, silent far-end) used 5.3% of this 4-core machine and missed the 5% gate. v1.3 used 14.9%. Both finished each hop before the next one was due. Both left speech near -45 dBFS. They are not linked into NearMic.

## DPDFNet

[HushMic](https://github.com/Fovty/HushMic) `da61fd4`, native runtime, not ONNX. "0.1 times real time" in HushMic's notes means a realtime factor of 0.1 on one core: about ten times faster than realtime. The 80 ms number is delay, not compute. The code's latency constant is 50 ms.

Measured on this Xeon with the AVX-VNNI kernels:

- `dpdfnet8_48khz_hr`: one-core realtime factor 0.115, hop p99 1.20 ms against a 10 ms hop, machine CPU 0.029, impulse peak at sample 2400 (50.00 ms), tail ratio 0.012 against a raw tail of 0.333.
- `dpdfnet2_48khz_hr`: one-core realtime factor 0.051, hop p99 0.57 ms, machine CPU 0.013, same 50.00 ms delay, tail ratio 0.034.

Both are under the CPU gate. At the model's own level, model 8 leaves speech at -32 dBFS and fails the loudness gate. The shipped speech-gated leveler then fails the pause gate. A constant +6 dB makeup, chosen on this clip, passes every gate and would win the written tie-break against `dsp-dereverb` because the tail is so much shorter. That gain is not automatic, and the weights are a 14 MB file. The release binary stays `dsp-dereverb`.

## ClearerVoice-Studio

[ClearerVoice](https://github.com/modelscope/ClearerVoice-Studio) ran on CPU PyTorch 2.15, because this machine has no CUDA and the loader turns CUDA off when it is absent. MossFormer2_SE_48K finished a 4 second clip in 0.42 s of wall time and used 10.7% of the machine, with its configured decode window at 4 seconds. FRCRN_SE_16K took 20.4 s for 4 s of audio. MossFormerGAN_SE_16K took 7.4 s. All three left this synthetic voice below -50 dBFS. The rows are in [AI.md](AI.md). They are not part of the single binary.

## What was copied anyway

From HushMic: the audio callback only moves samples, bypass and mute keep the same delay, and the worker stops when nobody is recording the virtual mic.

From LocalVQE: one small streaming hop, one thread, no GPU. The hop that shipped is the 256-sample Zig FFT, which is the same idea at 48 kHz.

From ClearerVoice: the device stays at 48 kHz. Multi-second overlap-add stays out of the live path.
