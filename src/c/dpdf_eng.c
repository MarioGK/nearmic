#include "dpdfnet.h"

#include <fftw3.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define NFFT 960
#define HOP 480
#define BINS 481

typedef struct DpdfEng {
    dpdfnet_model *model;
    float *state;
    float *next;
    size_t state_n;
    float window[NFFT];
    float ring[NFFT];
    float ola[NFFT];
    fftwf_complex *time;
    fftwf_complex *freq;
    fftwf_plan fwd;
    fftwf_plan inv;
} DpdfEng;

int dpdf_eng_cpu_ok(void) {
    return dpdfnet_cpu_supported();
}

static void window_init(float *window) {
    const float h = (float)NFFT / 2.0f;
    int n;
    for (n = 0; n < NFFT; n++) {
        float sn = sinf(0.5f * (float)M_PI * ((float)n + 0.5f) / h);
        window[n] = sinf(0.5f * (float)M_PI * sn * sn);
    }
}

static void analyze(DpdfEng *s, const float *hop, float *spec) {
    int i, k;
    memmove(s->ring, s->ring + HOP, (NFFT - HOP) * sizeof(float));
    memcpy(s->ring + NFFT - HOP, hop, HOP * sizeof(float));
    for (i = 0; i < NFFT; i++) {
        s->time[i][0] = s->ring[i] * s->window[i];
        s->time[i][1] = 0;
    }
    fftwf_execute(s->fwd);
    for (k = 0; k < BINS; k++) {
        spec[2 * k] = s->freq[k][0];
        spec[2 * k + 1] = s->freq[k][1];
    }
}

static void synthesize(DpdfEng *s, const float *spec, float *hop) {
    int k, j, i;
    const float norm = 1.0f / (float)NFFT;
    for (k = 0; k < BINS; k++) {
        s->freq[k][0] = spec[2 * k];
        s->freq[k][1] = spec[2 * k + 1];
    }
    for (j = BINS; j < NFFT; j++) {
        s->freq[j][0] = s->freq[NFFT - j][0];
        s->freq[j][1] = -s->freq[NFFT - j][1];
    }
    fftwf_execute(s->inv);
    memmove(s->ola, s->ola + HOP, (NFFT - HOP) * sizeof(float));
    memset(s->ola + NFFT - HOP, 0, HOP * sizeof(float));
    for (i = 0; i < NFFT; i++) s->ola[i] += s->time[i][0] * norm * s->window[i];
    memcpy(hop, s->ola, HOP * sizeof(float));
}

DpdfEng *dpdf_eng_new(int model_id, const float *weights, size_t count) {
    dpdfnet_model_id id = model_id == 2 ? DPDFNET_MODEL_2 : DPDFNET_MODEL_8;
    const dpdfnet_model_info *info = dpdfnet_get_model_info(id);
    DpdfEng *eng;
    if (!info || count != info->weight_floats) return NULL;
    eng = calloc(1, sizeof(*eng));
    if (!eng) return NULL;
    window_init(eng->window);
    eng->time = fftwf_alloc_complex(NFFT);
    eng->freq = fftwf_alloc_complex(NFFT);
    if (!eng->time || !eng->freq) goto fail;
    eng->fwd = fftwf_plan_dft_1d(NFFT, eng->time, eng->freq, FFTW_FORWARD, FFTW_ESTIMATE);
    eng->inv = fftwf_plan_dft_1d(NFFT, eng->freq, eng->time, FFTW_BACKWARD, FFTW_ESTIMATE);
    if (!eng->fwd || !eng->inv) goto fail;
    eng->model = dpdfnet_create(id, weights, count);
    if (!eng->model) goto fail;
    eng->state_n = info->state_floats;
    eng->state = calloc(eng->state_n, sizeof(float));
    eng->next = calloc(eng->state_n, sizeof(float));
    if (!eng->state || !eng->next) goto fail;
    if (dpdfnet_init_state(id, eng->state) != 0) goto fail;
    return eng;
fail:
    if (eng->fwd) fftwf_destroy_plan(eng->fwd);
    if (eng->inv) fftwf_destroy_plan(eng->inv);
    if (eng->time) fftwf_free(eng->time);
    if (eng->freq) fftwf_free(eng->freq);
    if (eng->model) dpdfnet_destroy(eng->model);
    free(eng->state);
    free(eng->next);
    free(eng);
    return NULL;
}

void dpdf_eng_free(DpdfEng *eng) {
    if (!eng) return;
    if (eng->fwd) fftwf_destroy_plan(eng->fwd);
    if (eng->inv) fftwf_destroy_plan(eng->inv);
    if (eng->time) fftwf_free(eng->time);
    if (eng->freq) fftwf_free(eng->freq);
    dpdfnet_destroy(eng->model);
    free(eng->state);
    free(eng->next);
    free(eng);
}

void dpdf_eng_process(DpdfEng *eng, const float *in, float *out) {
    float spec[962];
    float spec_e[962];
    analyze(eng, in, spec);
    if (dpdfnet_process(eng->model, spec, eng->state, spec_e, eng->next) != 0) {
        memset(out, 0, HOP * sizeof(float));
        return;
    }
    memcpy(eng->state, eng->next, eng->state_n * sizeof(float));
    synthesize(eng, spec_e, out);
}
