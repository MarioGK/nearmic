# AI models on the same fixture

Machine: Intel Xeon, 4 cores, AVX2, AVX-VNNI, and AVX-512. CPU is process time divided by audio duration divided by core count. A row passes only when every gate in [RESULTS.md](RESULTS.md) holds. The clips are the synthetic files from `nearmic fixture` (4.0 s, noise amplitude 0.004, five harmonics in 170 ms bursts, echoes at 25, 54, and 100 ms). This is not a Comica VM40 recording.

The in-binary bake-off still picks **dsp-dereverb**. That row is copied here so the comparison is on one page.

| engine | pass | cpu | x realtime | p99 ms | block ms | delay ms | speech in | speech out | loudness error | pause in | pause out | tail ratio |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dsp-dereverb | yes | 0.0003 | 578 | 0.009 | 5.333 | 5.33 | -28.9 | -20.3 | 2.3 | -42.1 | -41.0 | 0.072 |
| rnnoise | no | 0.0130 | 17 | 0.581 | 10.000 | n/a | -28.9 | -62.4 | 44.4 | -42.1 | -51.0 | n/a |
| dpdfnet8 | no | 0.0288 | 8 | 1.198 | 10.000 | 50.00 | -28.9 | -32.0 | 14.0 | -42.1 | -45.5 | 0.012 |
| dpdfnet8+level | no | 0.0288 | 8 | 1.198 | 10.000 | 50.00 | -28.9 | -20.6 | 2.6 | -42.1 | -33.5 | 0.012 |
| dpdfnet8+6dB | yes | 0.0288 | 8 | 1.198 | 10.000 | 50.00 | -28.9 | -26.0 | 8.0 | -42.1 | -39.5 | 0.012 |
| dpdfnet8+8dB | yes | 0.0288 | 8 | 1.198 | 10.000 | 50.00 | -28.9 | -24.0 | 6.0 | -42.1 | -37.5 | 0.012 |
| dpdfnet2 | no | 0.0128 | 18 | 0.569 | 10.000 | 50.00 | -28.9 | -29.9 | 11.9 | -42.1 | -43.6 | 0.034 |
| dpdfnet2+level | no | 0.0128 | 18 | 0.569 | 10.000 | 50.00 | -28.9 | -19.6 | 1.6 | -42.1 | -32.7 | 0.034 |
| dpdfnet2+6dB | yes | 0.0128 | 18 | 0.569 | 10.000 | 50.00 | -28.9 | -23.9 | 5.9 | -42.1 | -37.6 | 0.034 |
| dpdfnet2+8dB | no | 0.0128 | 18 | 0.569 | 10.000 | 50.00 | -28.9 | -21.9 | 3.9 | -42.1 | -35.6 | 0.034 |
| localvqe-v1.2 | no | 0.0527 | 4 | 3.580 | 16.000 | 16.96 | -28.9 | -45.7 | 27.7 | -42.1 | -70.4 | 0.133 |
| localvqe-v1.2+level | no | 0.0527 | 4 | 3.580 | 16.000 | 16.96 | -28.9 | -32.0 | 14.0 | -42.1 | -60.5 | 0.133 |
| localvqe-v1.3 | no | 0.1489 | 2 | 9.907 | 16.000 | 16.94 | -28.9 | -44.4 | 26.4 | -42.1 | -89.7 | 0.004 |
| localvqe-v1.3+level | no | 0.1489 | 2 | 9.907 | 16.000 | 16.94 | -28.9 | -30.1 | 12.1 | -42.1 | -96.2 | 0.004 |
| mossformer2-48k | no | 0.1072 | 10 | 416.609 | 4000.000 | n/a | -28.9 | -55.9 | 37.9 | -42.1 | -62.9 | n/a |
| frcrn-16k | no | 4.7458 | 0 | 20412.371 | 4000.000 | 50.94 | -28.9 | -51.2 | 33.2 | -42.1 | -59.6 | 0.321 |
| mossformer-gan-16k | no | 1.8431 | 1 | 7433.721 | 4000.000 | n/a | -28.9 | -70.1 | 52.1 | -42.1 | -65.8 | n/a |

`+level` is the shipped speech-gated leveler (`Chain.init(false, false)`) run on the model output. `+6dB` and `+8dB` are constant makeup gains applied after the model. They cost nothing and do not change the tail ratio. They were chosen after seeing the native level. Raw impulse tail is 0.333.

## DPDFNet is not slow

HushMic's "0.1 times real time" is a realtime factor: one AVX2 core spends about a tenth of the audio duration. That is about 10 times faster than realtime, not a failure to keep up. The 80 ms figure in the README is algorithmic delay. The crate pins latency at `5 * 480` samples, which is 50 ms.

Measured here, native weights, AVX-VNNI kernels enabled (`dpdfnet_cpu_supported` returned 1):

| model | one-core RTF from CPU time | p99 of the whole hop | p99 of `dpdfnet_process` only | hop | delay |
| --- | ---: | ---: | ---: | ---: | ---: |
| dpdfnet8_48khz_hr | 0.115 | 1.198 ms | 1.189 ms | 10 ms | 2400 samples, 50.00 ms |
| dpdfnet2_48khz_hr | 0.051 | 0.569 ms | 0.559 ms | 10 ms | 2400 samples, 50.00 ms |

The FFT is not the cost. Model 8 is 8 times faster than its hop at the 99th percentile and uses 2.9% of this 4-core machine. Model 2 uses 1.3%. Both are under the 5% gate. The earlier claim that DPDFNet could not keep up was a misread of that realtime factor.

What model 8 misses at its native level is loudness. Speech leaves at -32.0 dBFS, 14 dB from the -18 dBFS target, while pauses fall to -45.5 dBFS. The shipped leveler then pulls speech to -20.6 dBFS and lifts pauses to -33.5 dBFS, which fails the 6 dB pause gate, because its release holds gain across the 170 ms bursts. A fixed +6 dB or +8 dB makeup passes every gate for model 8. A fixed +8 dB on model 2 lifts pauses by 6.5 dB and fails. The impulse peak sat on sample 2400 for both models, so the tail ratios are aligned with the real group delay, not with a noise spike.

If those makeup rows are scored with `dsp-dereverb` under the rule in `src/bench.zig`, the best passing tail is 0.012, so the room score counts. `dsp-dereverb` at 0.072 is outside 15% of that tail. The best pause drop belongs to `dsp-dereverb` (pauses fall 1.1 dB). Model 8 at +8 dB raises pauses by 4.6 dB and falls outside 3 dB of that drop. Model 8 at +6 dB raises pauses by 2.6 dB and stays inside it. Model 2's tail, 0.034, is outside the tail band. The only row in both bands is `dpdfnet8+6dB`.

That does not change the binary. The passing row is a constant gain picked on this synthetic clip, the speech-gated leveler does not reproduce it, and shipping it means vendoring the generated runtime plus the 14 MB `dpdfnet8_48khz_hr.weights.f32`. `dsp-dereverb` is still the only engine that passes with no weight file. On a real VM40 recording the same tail gap would be a reason to ship model 8 with a leveler that ducks pauses.

## RNNoise

Commit `70f1d25`, built `-O3 -mavx2 -mfma`, `rnnoise_create(NULL)`, samples scaled by 32768 the way the official demo does. CPU 1.3% of the machine, p99 0.58 ms against a 10 ms frame, about 17 times the frame rate. Fast enough.

On this fixture it follows the first burst and then removes the later ones. The scorer ignores the first 0.5 s, and speech in the scored window is -62 dBFS. The impulse peak is -91 dBFS, so the delay and tail columns are not a latency measurement. The synthetic harmonics are a poor stand-in for the speech RNNoise was trained on. The speed number stands. The quality number says it failed this clip, not that the runtime is heavy. The weight object is the generated `rnnoise_data.c` (about 75 MB of source) and stays out of the release binary.

## LocalVQE

Commits: LocalVQE `7f61cd0`, GGML submodule `c044a8e`. Built with `gcc`/`g++`, `Release`, `LOCALVQE_BUILD_SHARED=ON`, `GGML_NATIVE=OFF`. Runtime: CPU backend, 1 thread, silent far-end reference, `localvqe_process_frame_f32` hops of 256 samples at 16 kHz. Models `localvqe-v1.2-1.3M-f32.gguf` and `localvqe-v1.3-4.8M-f32.gguf`. GGML loaded `libggml-cpu-sapphirerapids.so` on this CPU.

| model | audio in the CPU loop | CPU seconds | one-core RTF | machine CPU | p99 | hop |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| v1.2 | 8.0 s | 1.686 | 0.211 | 0.0527 | 3.58 ms | 16 ms |
| v1.3 | 4.0 s | 2.382 | 0.596 | 0.1489 | 9.91 ms | 16 ms |

Both keep up with their hop. v1.2 misses the 5% machine gate by a small margin (0.0527). v1.3 uses about 15% and is out. Speech stays near -45 dBFS. The shipped leveler will not lift a signal whose presence sits below its -42 dBFS speech threshold, so the leveled rows are still 12 to 14 dB quiet. Pauses are very quiet. The 16 kHz files were upsampled 3x before scoring, and the impulse peak landed at about 17 ms.

## ClearerVoice-Studio

Clone of https://github.com/modelscope/ClearerVoice-Studio at `6b3774d`, package version 0.1.2 in `pyproject.toml`. PyTorch 2.15.0+cpu, no CUDA. The yaml files ask for CUDA. `networks.py` sees that CUDA is missing and sets `use_cuda = 0`, so these numbers are the CPU path. PyTorch used more than one core: process CPU time is several times the wall clock.

The block in the table is the whole 4 second clip. MossFormer2's config sets `decode_window: 4` seconds, so that block is also its live window. "10 times realtime" there means the 4 second chunk finished in 0.42 s of wall time. A live mic still has to wait for that window. FRCRN's config window is 1 second, but the timed call is the whole clip.

| model | wall for 4 s | process CPU | machine CPU | speech out | notes |
| --- | ---: | ---: | ---: | ---: | --- |
| MossFormer2_SE_48K | 0.417 s | 5.147 s over 12 s of audio | 0.107 | -55.9 dBFS | impulse peak sits on sample 0, so delay and tail are not a latency reading |
| FRCRN_SE_16K | 20.412 s | 75.933 s over 4 s of audio | 4.746 | -51.2 dBFS | slower than realtime; impulse peak at 51 ms; tail 0.321 against raw 0.333 |
| MossFormerGAN_SE_16K | 7.434 s | 29.489 s over 4 s of audio | 1.843 | -70.1 dBFS | slower than realtime; impulse peak is -76 dBFS, so delay is not real |

All three fail. They are quiet on this synthetic voice, and FRCRN and MossFormerGAN do not keep up with the audio. The shipped leveler ducks them further because the presence sits below -42 dBFS. None of this belongs in the realtime binary.

## How the numbers were produced

Trees and weights stay outside the git repo. Checksums of the weight files matched the native runtime before `dpdfnet_create`:

- `dpdfnet8_48khz_hr.weights.f32` sha256 `5a5bb67a8619090c54dc2793536fe813fe38123b236d445f3433aafe3075529d`
- `dpdfnet2_48khz_hr.weights.f32` sha256 `cb7248b8fccbff7b32f254ec2ed0061e604514b2ccd98d997cd081a876424e7b`

HushMic `da61fd4`. The native runtime was compiled the way `crates/hushmic-denoiser/build.rs` compiles it: gnu11, `-O3`, `NDEBUG`, `-ffp-contract=off`, per-model `-include namespace{2,8}.h`, AVX2, FMA, F16C, and AVX-VNNI. The waveform path is the crate's Vorbis window, hop 480, FFT 960, with FFTW single precision. `p99` is the whole hop after 20 warmup hops. CPU time is a separate loop of at least 1.2 s of wall time, and the scorer divides by the audio those loops actually processed.

Runners: `scripts/ai/rnnoise_run.c`, `scripts/ai/localvqe_run.c`, `scripts/ai/dpdfnet_run.c`, `scripts/ai/build_dpdfnet.sh`. Scoring is `nearmic score`.
