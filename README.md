# NearMic

A Linux virtual microphone for a voice that is too far from the mic. NearMic is one executable. It reads the microphone you choose, makes the voice louder and steadier, lowers stationary noise, and publishes a PipeWire source named **NearMic**. Discord, OBS, and the browser can select that source.

The processing that ships is the only chain that passed the bake-off gates on the shared fixture. It is `dsp-dereverb`: an 80 Hz high-pass, a causal spectral denoiser, a delayed spectral dereverb, a 3.5 kHz presence shelf, a speech-gated leveler aimed at -18 dBFS, and a soft limiter. The leveler reads the signal after the denoiser, so it makes up the gain the denoiser removes.

On the 4-core Xeon that ran the bake-off, that chain used 0.0003 of the machine and the 99th percentile 5.333 ms block took 0.012 ms, hundreds of times faster than realtime. Speech entered at -28.9 dBFS and left at -20.3 dBFS. Pauses moved from -42.1 dBFS to -41.0 dBFS. The impulse tail ratio fell from 0.333 to 0.072. The same chain without the dereverb raised pauses by 6.2 dB and failed that gate. The leveler alone and SpeexDSP left the tail at 0.333 and 0.327. The fixture is synthetic. It is not a recording of a Comica VM40. The table is [bench/RESULTS.md](bench/RESULTS.md). Audio levels stay put across runs. The sub-millisecond p99 moves a little.

RNNoise, LocalVQE, DPDFNet, and ClearerVoice were run on the same fixture. DPDFNet model 8 took 1.20 ms at the 99th percentile of a 10 ms hop (a realtime factor of 0.12 on one core, 2.9% of this 4-core machine) with 50 ms of delay. It is fast. It leaves speech at -32 dBFS, so it fails the loudness gate until a makeup gain of about +6 dB is added. ClearerVoice's FRCRN and MossFormerGAN were slower than the audio. The rows are in [bench/AI.md](bench/AI.md). `zig build bakeoff` exits with an error if the shipped engine is not the measured winner. That engine stays `dsp-dereverb`. A release build can also link RNNoise and native DPDFNet. LocalVQE is optional and loaded with `dlopen` only when its shared library and gguf are already present. ClearerVoice stays selectable and reports why it is not run.

## Run

PipeWire and WirePlumber need to be running. Build with Zig 0.14.1:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/nearmic
```

With no arguments, and from the desktop menu, NearMic installs itself. It copies the binary to `~/.local/bin/nearmic`, writes `~/.config/systemd/user/nearmic.service`, and starts a user service that runs `nearmic run`. The same command is `nearmic setup`. If systemd --user is not available, the daemon stays in the foreground. Pick **NearMic** as the input. Turn off the noise suppressor in Discord or the browser so two denoisers do not fight.

```sh
nearmic run                  # foreground daemon
nearmic engines
nearmic engine dsp-dereverb
nearmic gain 0
nearmic qa
nearmic status
nearmic mode bypass          # raw voice, same delay
nearmic mode mute
nearmic mode suppress
nearmic listen on            # headphones. speakers will feed the mic
nearmic doctor
nearmic enhance in.wav out.wav
nearmic quit
```

`enhance` reads and writes 48 kHz WAV and uses the engine in the config file. Stereo input is mixed to mono.

Config is `~/.config/nearmic/config.toml`. `engine`, `mode`, `listen`, `gain_db`, `profile`, `threads`, and `cpu_budget` are picked up between audio blocks while the daemon is running. A thread-count change rebuilds the worker pool then. A bad edit keeps the previous config. Changing `source` applies the next time the daemon starts, so it does not reopen PipeWire underneath the stream.

```toml
profile = "desktop"
engine = "dsp-dereverb"
mode = "suppress"
listen = false
gain_db = 0.0
source = ""
# threads = 1
# cpu_budget = 0.05
```

`source` is the PipeWire node name of the real microphone. Leave it empty and NearMic captures whichever source was the default when it started. It never captures itself. Set `NEARMIC_NO_DEFAULT=1` if NearMic should not become the default source.

The default engine is still `dsp-dereverb`. Its delay is one 256-sample hop, about 5.3 ms, and suppress, bypass, and mute keep that delay. Other engines keep their own fixed delay. `gain_db` is makeup after the engine. DPDFNet model 8 sits near -32 dBFS on the synthetic fixture until `gain_db` is about 6. `dsp-dereverb` does not need that.

The deployed ROCK 4 Plus appliance overrides the default with `engine = "rnnoise"`, `gain_db = 10`, `threads = 1`, `cpu_budget = 0.80`; RNNoise plus `voice.Post` is the natural full-band chain, while `dsp-dereverb` was the robotic one on the rock profile. See [rockpi4/QUALITY.md](rockpi4/QUALITY.md).

`nearmic engines` lists every measured engine and whether this binary can run it. `nearmic qa` runs the ones it can. It exits 1 if `leveler`, `dsp`, `dsp-dereverb`, or `speex-dereverb` emits non-finite audio, or if `dsp-dereverb` misses the loudness or pause gate. It also runs the `rock-pi-plus` profile on this machine: more than one DSP thread, a 0.90 budget, finite audio, and the same loudness and pause gates. That profile does not replace the 0.05 desktop CPU gate. Anything not linked is a skip. SpeexDSP is linked into the binary. A release build also links RNNoise and native DPDFNet (`scripts/bundle.sh`, then `zig build -Dbundle=true`). DPDFNet weights are checked by sha256 and stored in `~/.local/share/nearmic/` (`nearmic fetch`, or the first time that engine is selected). LocalVQE is not linked into the binary. It runs only when `liblocalvqe.so` and its gguf are already on disk, loaded with `dlopen`. If either file is missing, `nearmic engines` and `qa` skip it and say why. ClearerVoice is PyTorch and is never run; `qa` skips it.

## ROCK 4 Plus V1.73

`profile = "rock-pi-plus"` is the Radxa ROCK Pi 4 Plus, PCB V1.73 (ROCK 4A+ and ROCK 4B+ share that board). It is not a ROCK 5.

| | |
| --- | --- |
| SoC | Rockchip OP1, the 2.0 GHz bin of the RK3399 |
| CPU | 2x Cortex-A72 + 4x Cortex-A53 (6 cores) |
| GPU | Mali-T860MP4, OpenGL ES 3.2, Vulkan 1.0, OpenCL 1.1/1.2 |
| NPU | none. The RK3399Pro has an NPU; OP1 does not |
| RAM | 2 GB or 4 GB LPDDR4 |

The profile sets `cpu_budget` to 0.90 and `threads` to 0. Zero means every core, and the pool never starts more DSP threads than `nproc`. An explicit `threads` or `cpu_budget` line overrides the profile. `profile = "desktop"` is the default: `dsp-dereverb`, one DSP thread, budget 0.05. That is still the bake-off gate.

```sh
# On the board, or from an x86 machine. -Dcpu may be omitted; aarch64
# without a CPU still pins cortex-a53 so the same binary can run on
# either cluster. Both the A72 and the A53 are ARMv8-A with NEON.
# The appliance uses glibc (musl cannot dlopen Debian's PipeWire):
scripts/build-rnnoise-aarch64.sh
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu -Dcpu=cortex_a53 -Dbundle=true
```

The hot path is `@Vector(4, f32)` in the 512/1024/2048 FFT and in the window multiply. On this target that is NEON (`fmul` / `fadd` on `v` registers, `.4s`). The x86_64 build lowers the same vectors to SSE. The PipeWire callback only copies samples. DSP runs on the worker, which fans the rock profile's jobs out to the pool.

For `dsp-dereverb` and `dsp`, the rock profile runs an ensemble instead of the single desktop chain: up to three 512-point denoise/dereverb hypotheses, averaged with the stronger one weighted more, plus 1024- and 2048-point noise trackers that push stationary bins down. The leveler is unchanged, so speech stays near -18 dBFS. Delay stays one 256-sample hop, about 5.3 ms. Other engines (Speex, RNNoise, DPDFNet, LocalVQE) are not multithreaded. DPDFNet in this tree is AVX2 and is not the ARM path.

What is actually compiled in, and what is only detected:

| | Compiled in | Used at runtime |
| --- | --- | --- |
| NEON STFT (`-mcpu=cortex-a53`) | yes, on the aarch64 build | yes, whenever that binary runs the FFT |
| Extra DSP threads | yes | yes, when `profile = "rock-pi-plus"` |
| RKNN / RKNPU | no model, no toolkit calls that run a network | no. `librknnrt.so`, `/dev/rknpu`, and `~/.local/share/nearmic/enhancer.rknn` are checked. All three missing, or present without a tensor map, keeps the CPU ensemble. `accel.selectNpu` is that hook and it returns false |
| Mali OpenCL | no kernel | no. `libOpenCL.so` or `libmali.so` is reported by `nearmic doctor` and `nearmic qa` and is not called. A 256-sample hop is smaller than a useful GPU launch |

SpeexDSP is linked only when the target is x86_64 and `/usr/lib/x86_64-linux-gnu/libspeexdsp.a` is present. The aarch64 appliance binary is **glibc**, because a static musl binary cannot `dlopen` Debian's glibc PipeWire. Speex is skipped on aarch64; RNNoise is statically linked with `-Dbundle=true`.

These numbers were measured on the build machine, a 4-core Xeon, not on a ROCK 4 Plus. `nearmic qa` there reported the rock profile at 4 threads, budget 0.90, p99 0.052 ms of the 5.333 ms hop, CPU 0.0031 (process CPU time / audio seconds / nproc), speech -20.4 dBFS, pause -42.6 dBFS. Desktop `dsp-dereverb` on the same fixture was speech -20.4 dBFS and pause -41.1 dBFS. The same `cortex_a53` binary under `qemu-aarch64-static` on that Xeon reported `simd=neon`, `cpu_model=cortex_a53`, p99 0.869 ms, and the same speech and pause levels. Its CPU fraction read as 0 because qemu-user's `/proc/self/stat` is not the board's accounting. Nothing here was timed on the ROCK 4 Plus itself.

## What the chain does

The leveler is what makes a quiet voice loud. Gain moves only while the frame is above the speech threshold, freezes when it is not, and is capped at +30 dB. A fast gate ducks pauses so the frozen gain does not turn the room into a roar. The spectral denoiser runs before the leveler, so noise is not what gets amplified.

## Bake-off

```sh
sudo apt-get install pkg-config libpipewire-0.3-dev libspeexdsp-dev
zig build test
zig build bakeoff -Doptimize=ReleaseFast
```

`zig build bakeoff` rewrites `bench/RESULTS.md`. The winner among those linked bake-off engines is still `dsp-dereverb`, and that is the name `engineName()` reports. SpeexDSP is linked into `nearmic` as a static library. `ldd` on `nearmic` should show only the system C library, libm, libdl, and libpthread. PipeWire is loaded with `dlopen` when the live mic starts.

GitHub Actions builds that binary on every push and pull request. A tag `v*` runs `scripts/bundle.sh`, links RNNoise and DPDFNet, and uploads `nearmic-linux-x86_64` to the GitHub Release. `zig build` without `-Dbundle=true` stays usable when those trees are not present.

## Limits

This will not turn a Comica VM40 at two meters into a microphone on the chin. It will make the voice louder, steadier, and less hissy, and it takes some of the room bloom out. Hearing it in a call has to happen on the PipeWire machine that has the microphone.
