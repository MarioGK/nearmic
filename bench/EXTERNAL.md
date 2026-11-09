# Candidates outside the shipped binary

The live bake-off in [RESULTS.md](RESULTS.md) measured four engines on one synthetic fixture: a leveler, the Zig spectral denoiser plus leveler (`dsp`), the same chain with a delayed spectral dereverb (`dsp-dereverb`), and SpeexDSP denoise plus dereverb followed by the Zig leveler. `dsp-dereverb` is the only row that passed every gate, and it is the engine in the binary.

These others were part of the design review and were not given a row in that table.

## RNNoise

The current Xiph tree downloads its weights as a generated C file of about 78 MB (`rnnoise_data.c`). Compiling that into the bake-off binary dominates the build and the release file. The classical spectral denoiser is the lightweight measurement in its place. RNNoise remains a reasonable later candidate if a small weight blob is vendored on purpose.

## LocalVQE

[LocalVQE](https://github.com/localai-org/LocalVQE) v1.2 is the small causal model (1.3 M parameters, 16 kHz, 16 ms hops) that matches the "less distant" goal on paper. The repository and its GGML submodule were cloned here. Configure did not finish: `/usr/bin/c++` is Clang, and the unversioned `libstdc++` linker script lives in GCC's private directory (`/usr/lib/gcc/x86_64-linux-gnu/13/libstdc++.so`), which that driver does not search. LocalVQE is not linked into NearMic. Published numbers on a Ryzen 9 7900 put v1.2 near 4 ms per 16 ms hop on one thread, which would fit a 5% machine budget, and v1.3 is the one likely to miss it on a 5800X. Shipping it would also mean embedding GGML. The bake-off ships the lightest passer, and that passer is the Zig chain.

## DPDFNet

[HushMic](https://github.com/Fovty/HushMic) uses DPDFNet at 48 kHz. Its own notes put the native AVX2 engine near 0.1 times realtime on one desktop core, with 80 ms of delay. That CPU cost fits the budget. The model is a noise suppressor. It does not restore level and it does not remove the room sound that makes a distant mic sound far, which is why it was not the default engine. The native runtime is a large generated C and assembly tree plus weight files fetched by HushMic's setup script. It was not rebuilt in this bake-off.

## ClearerVoice-Studio

[ClearerVoice](https://github.com/modelscope/ClearerVoice-Studio) MossFormer2 at 48 kHz and FRCRN at 16 kHz are the quality ceiling. Their inference configs request CUDA and decode in windows of 1 to 10 seconds. That misses the live latency gate before any CPU number is taken, so they were not run as candidates. They also need PyTorch checkpoints that do not belong in a single realtime binary.

## What was copied anyway

From HushMic: the audio callback only moves samples, bypass and mute keep the same delay, and the worker stops when nobody is recording the virtual mic.

From LocalVQE: one small streaming hop, one thread, no GPU. The hop that shipped is the 256-sample Zig FFT, which is the same idea at 48 kHz.

From ClearerVoice: the device stays at 48 kHz. Multi-second overlap-add stays out of the live path.
