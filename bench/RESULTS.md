# Bake-off

Machine: Intel(R) Xeon(R) Processor, 4 cores. CPU is process time divided by audio duration divided by core count, so 0.05 is 5% of the whole machine while keeping up with 48 kHz.

Fixture: 4.0 seconds at 48 kHz. Stationary noise at amplitude 0.004, five harmonics in 170 ms bursts, then three echoes at 25 ms, 54 ms, and 100 ms. This is synthetic. It is not a recording of a Comica VM40.

A row passes only when every gate holds: p99 block time is under the block duration, CPU is at or under 0.05, speech RMS is above -36 dBFS, speech RMS is within 8 dB of -18 dBFS, and pause RMS does not rise more than 6 dB.

Raw impulse tail ratio: 0.333

| engine | pass | cpu | x realtime | p99 ms | block ms | delay ms | speech in | speech out | loudness error | pause in | pause out | tail ratio |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| leveler | no | 0.0001 | 945 | 0.006 | 5.333 | 0.00 | -28.9 | -19.4 | 1.4 | -42.1 | -31.8 | 0.333 |
| dsp | no | 0.0003 | 605 | 0.009 | 5.333 | 5.33 | -28.9 | -19.2 | 1.2 | -42.1 | -35.9 | 0.120 |
| dsp-dereverb | yes | 0.0003 | 578 | 0.009 | 5.333 | 5.33 | -28.9 | -20.3 | 2.3 | -42.1 | -41.0 | 0.072 |
| speex-dereverb | no | 0.0007 | 325 | 0.246 | 80.000 | 10.00 | -28.9 | -19.5 | 1.5 | -42.1 | -32.6 | 0.327 |

Winner: **dsp-dereverb**

Best passing tail ratio 0.072 against raw 0.333. The room score counts, because that tail is under 90% of raw. Among passers that stay within 15% of that tail and within 3 dB of the best pause drop, the lowest CPU wins. A CPU gap under 10% (or 0.0002) is a tie, broken by the lower tail ratio and then the smaller loudness error.

## Not in this binary

- RNNoise current weights are a generated 78 MB C file downloaded at build time. It was left out of the single binary so the release stays one small file. The classical denoise above is the lightweight stand-in.
- LocalVQE, DPDFNet, and ClearerVoice are reference designs. ClearerVoice's published models decode in 1 to 10 second windows and want CUDA, so they miss the live gates without a separate measurement. LocalVQE and DPDFNet are not linked here; see bench/EXTERNAL.md for the build attempt.
