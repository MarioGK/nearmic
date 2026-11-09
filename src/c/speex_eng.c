#include <speex/speex_preprocess.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

typedef struct SpeexEng {
    SpeexPreprocessState *st;
    int frame;
} SpeexEng;

SpeexEng *speex_eng_new(int dereverb) {
    SpeexEng *eng = calloc(1, sizeof(*eng));
    if (!eng) return NULL;
    eng->frame = 480;
    eng->st = speex_preprocess_state_init(eng->frame, 48000);
    if (!eng->st) {
        free(eng);
        return NULL;
    }
    int on = 1;
    int off = 0;
    int suppress = -24;
    int max_gain = 30;
    float level = 8000.0f;
    speex_preprocess_ctl(eng->st, SPEEX_PREPROCESS_SET_DENOISE, &on);
    speex_preprocess_ctl(eng->st, SPEEX_PREPROCESS_SET_AGC, &off);
    speex_preprocess_ctl(eng->st, SPEEX_PREPROCESS_SET_VAD, &off);
    speex_preprocess_ctl(eng->st, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &suppress);
    speex_preprocess_ctl(eng->st, SPEEX_PREPROCESS_SET_AGC_LEVEL, &level);
    speex_preprocess_ctl(eng->st, SPEEX_PREPROCESS_SET_AGC_MAX_GAIN, &max_gain);
    speex_preprocess_ctl(eng->st, SPEEX_PREPROCESS_SET_DEREVERB, dereverb ? &on : &off);
    (void)level;
    return eng;
}

void speex_eng_free(SpeexEng *eng) {
    if (!eng) return;
    if (eng->st) speex_preprocess_state_destroy(eng->st);
    free(eng);
}

int speex_eng_frame(void) { return 480; }

void speex_eng_process(SpeexEng *eng, const float *in, float *out) {
    spx_int16_t buf[480];
    for (int i = 0; i < eng->frame; i++) {
        float x = in[i];
        if (x > 1) x = 1;
        if (x < -1) x = -1;
        buf[i] = (spx_int16_t)(x * 32767.0f);
    }
    speex_preprocess_run(eng->st, buf);
    for (int i = 0; i < eng->frame; i++) out[i] = (float)buf[i] / 32768.0f;
}
