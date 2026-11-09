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

Config is `~/.config/nearmic/config.toml`. `engine`, `mode`, `listen`, and `gain_db` are picked up while the daemon is running. A bad edit keeps the previous config. Changing `source` applies the next time the daemon starts, so it does not reopen PipeWire underneath the stream.

```toml
engine = "dsp-dereverb"
mode = "suppress"
listen = false
gain_db = 0.0
source = ""
```

`source` is the PipeWire node name of the real microphone. Leave it empty and NearMic captures whichever source was the default when it started. It never captures itself. Set `NEARMIC_NO_DEFAULT=1` if NearMic should not become the default source.

The default engine is still `dsp-dereverb`. Its delay is one 256-sample hop, about 5.3 ms, and suppress, bypass, and mute keep that delay. Other engines keep their own fixed delay. `gain_db` is makeup after the engine. DPDFNet model 8 sits near -32 dBFS on the synthetic fixture until `gain_db` is about 6. `dsp-dereverb` does not need that.

`nearmic engines` lists every measured engine and whether this binary can run it. `nearmic qa` runs the ones it can. It exits 1 if `leveler`, `dsp`, `dsp-dereverb`, or `speex-dereverb` emits non-finite audio, or if `dsp-dereverb` misses the loudness or pause gate. Anything not linked is a skip. SpeexDSP is linked into the binary. A release build also links RNNoise and native DPDFNet (`scripts/bundle.sh`, then `zig build -Dbundle=true`). DPDFNet weights are checked by sha256 and stored in `~/.local/share/nearmic/` (`nearmic fetch`, or the first time that engine is selected). LocalVQE is not linked into the binary. It runs only when `liblocalvqe.so` and its gguf are already on disk, loaded with `dlopen`. If either file is missing, `nearmic engines` and `qa` skip it and say why. ClearerVoice is PyTorch and is never run; `qa` skips it.

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
