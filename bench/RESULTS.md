# Bake-off

Same 4 second far-mic fixture on this machine. CPU is the share of the whole machine needed to keep up with 48 kHz audio. A row passes when the 99th percentile block is faster than realtime, that share stays at or under 5%, speech lands within 8 dB of -18 dBFS, and pauses do not rise more than 6 dB.

Raw impulse tail ratio: 0.333

| engine | pass | cpu | p99 ms | block ms | delay ms | speech dBFS | loudness error | pause in | pause out | tail ratio |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| leveler | no | 0.0001 | 0.006 | 5.333 | 0.00 | -19.3 | 1.3 | -42.1 | -31.7 | 0.333 |
| dsp | yes | 0.0007 | 0.016 | 5.333 | 5.33 | -23.2 | 5.2 | -42.1 | -38.4 | 0.120 |
| dsp-dereverb | no | 0.0007 | 0.017 | 5.333 | 5.33 | -27.5 | 9.5 | -42.1 | -44.8 | 0.072 |
| speex-dereverb | no | 0.0007 | 0.234 | 80.000 | 10.00 | -19.5 | 1.5 | -42.1 | -30.6 | 0.327 |

Winner: **dsp**

The best passing tail ratio is under 90 percent of the raw impulse, so the room score counts. The winner is the lightest passer near the best tail and the best pause drop.

## Not in this binary

- RNNoise current weights are a generated 78 MB C file downloaded at build time. It was left out of the single binary so the release stays one small file. The classical denoise above is the lightweight stand-in.
- LocalVQE, DPDFNet, and ClearerVoice are reference designs. ClearerVoice's published models decode in 1 to 10 second windows and want CUDA, so they miss the live gates without a separate measurement. LocalVQE and DPDFNet are not linked here; see bench/EXTERNAL.md for the build attempt.
