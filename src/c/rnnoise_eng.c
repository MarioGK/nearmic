#include "rnnoise.h"

#include <stdlib.h>

typedef struct RnnoiseEng {
    DenoiseState *st;
    float vad;
} RnnoiseEng;

RnnoiseEng *rnnoise_eng_new(void) {
    RnnoiseEng *eng = calloc(1, sizeof(*eng));
    if (!eng) return NULL;
    eng->st = rnnoise_create(NULL);
    if (!eng->st) {
        free(eng);
        return NULL;
    }
    return eng;
}

void rnnoise_eng_free(RnnoiseEng *eng) {
    if (!eng) return;
    if (eng->st) rnnoise_destroy(eng->st);
    free(eng);
}

void rnnoise_eng_process(RnnoiseEng *eng, const float *in, float *out) {
    float x[480];
    int i;
    for (i = 0; i < 480; i++) x[i] = in[i] * 32768.0f;
    eng->vad = rnnoise_process_frame(eng->st, x, x);
    for (i = 0; i < 480; i++) out[i] = x[i] / 32768.0f;
}

/* Speech probability (0..1) of the last processed frame. */
float rnnoise_eng_vad(const RnnoiseEng *eng) {
    return eng->vad;
}
