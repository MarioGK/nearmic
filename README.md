# NearMic

A Linux virtual microphone for a voice that is too far from the mic. NearMic is one executable. It reads the microphone you choose, makes the voice louder and steadier, lowers stationary noise, and publishes a PipeWire source named **NearMic**. Discord, OBS, and the browser can select that source.

The processing that ships is the only chain that passed the bake-off gates on the shared fixture. It is `dsp-dereverb`: an 80 Hz high-pass, a causal spectral denoiser, a delayed spectral dereverb, a 3.5 kHz presence shelf, a speech-gated leveler aimed at -18 dBFS, and a soft limiter. The leveler reads the signal after the denoiser, so it makes up the gain the denoiser removes.

On the 4-core Xeon that ran the bake-off, that chain used 0.0003 of the machine and the 99th percentile 5.333 ms block took 0.009 ms, 578 times faster than realtime. Speech entered at -28.9 dBFS and left at -20.3 dBFS. Pauses moved from -42.1 dBFS to -41.0 dBFS. The impulse tail ratio fell from 0.333 to 0.072. The same chain without the dereverb raised pauses by 6.2 dB and failed that gate. The leveler alone and SpeexDSP left the tail at 0.333 and 0.327. The fixture is synthetic. It is not a recording of a Comica VM40. The table is [bench/RESULTS.md](bench/RESULTS.md).

RNNoise, LocalVQE, DPDFNet, and ClearerVoice are discussed in [bench/EXTERNAL.md](bench/EXTERNAL.md). They are not inside the binary. `zig build bakeoff` exits with an error if the engine in the binary is not the measured winner.

## Run

PipeWire and WirePlumber need to be running. Build with Zig 0.14.1:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/nearmic
```

Pick **NearMic** as the input. Turn off the noise suppressor in Discord or the browser so two denoisers do not fight. Ctrl-C removes the source.

```sh
nearmic status
nearmic mode bypass          # raw voice, same delay
nearmic mode mute
nearmic mode suppress
nearmic listen on            # headphones. speakers will feed the mic
nearmic doctor
nearmic enhance in.wav out.wav
nearmic quit
```

`enhance` reads and writes 48 kHz WAV. Stereo input is mixed to mono.

Optional config at `~/.config/nearmic/config`:

```
source=alsa_input.usb-Comica_VM40
mode=suppress
listen=off
```

`source` is the PipeWire node name of the real microphone. Leave it empty and NearMic captures whichever source was the default when it started. It never captures itself. Set `NEARMIC_NO_DEFAULT=1` if NearMic should not become the default source.

The added delay is one 256-sample hop, about 5.3 ms, and it stays the same in suppress, bypass, and mute.

## What the chain does

The leveler is what makes a quiet voice loud. Gain moves only while the frame is above the speech threshold, freezes when it is not, and is capped at +30 dB. A fast gate ducks pauses so the frozen gain does not turn the room into a roar. The spectral denoiser runs before the leveler, so noise is not what gets amplified.

## Bake-off

```sh
sudo apt-get install pkg-config libpipewire-0.3-dev libspeexdsp-dev
zig build test
zig build bakeoff -Doptimize=ReleaseFast
```

`zig build bakeoff` rewrites `bench/RESULTS.md`. The release binary does not link SpeexDSP. `ldd` on `nearmic` should show only the system C library. PipeWire is loaded with `dlopen` when the live mic starts.

GitHub Actions builds that binary on every push and pull request. A tag `v*` uploads `nearmic-linux-x86_64` to the GitHub Release.

## Limits

This will not turn a Comica VM40 at two meters into a microphone on the chin. It will make the voice louder, steadier, and less hissy, and it takes some of the room bloom out. Hearing it in a call has to happen on the PipeWire machine that has the microphone.
