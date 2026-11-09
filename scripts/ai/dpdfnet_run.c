#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <fftw3.h>
#include "dpdfnet.h"

#define NFFT 960
#define HOP 480
#define BINS 481
#define SPEC 962

typedef struct {
    float window[NFFT];
    float ring[NFFT];
    float ola[NFFT];
    fftwf_complex *time;
    fftwf_complex *freq;
    fftwf_plan fwd;
    fftwf_plan inv;
} Stft;

static void stft_init(Stft *s) {
    const float h = (float)NFFT / 2.0f;
    for (int n = 0; n < NFFT; n++) {
        float sn = sinf(0.5f * (float)M_PI * ((float)n + 0.5f) / h);
        s->window[n] = sinf(0.5f * (float)M_PI * sn * sn);
    }
    memset(s->ring, 0, sizeof s->ring);
    memset(s->ola, 0, sizeof s->ola);
    s->time = fftwf_alloc_complex(NFFT);
    s->freq = fftwf_alloc_complex(NFFT);
    s->fwd = fftwf_plan_dft_1d(NFFT, s->time, s->freq, FFTW_FORWARD, FFTW_ESTIMATE);
    s->inv = fftwf_plan_dft_1d(NFFT, s->freq, s->time, FFTW_BACKWARD, FFTW_ESTIMATE);
}

static void analyze(Stft *s, const float *hop, float *spec) {
    memmove(s->ring, s->ring + HOP, (NFFT - HOP) * sizeof(float));
    memcpy(s->ring + NFFT - HOP, hop, HOP * sizeof(float));
    for (int i = 0; i < NFFT; i++) {
        s->time[i][0] = s->ring[i] * s->window[i];
        s->time[i][1] = 0;
    }
    fftwf_execute(s->fwd);
    for (int k = 0; k < BINS; k++) {
        spec[2 * k] = s->freq[k][0];
        spec[2 * k + 1] = s->freq[k][1];
    }
}

static void synthesize(Stft *s, const float *spec, float *hop) {
    for (int k = 0; k < BINS; k++) {
        s->freq[k][0] = spec[2 * k];
        s->freq[k][1] = spec[2 * k + 1];
    }
    for (int j = BINS; j < NFFT; j++) {
        s->freq[j][0] = s->freq[NFFT - j][0];
        s->freq[j][1] = -s->freq[NFFT - j][1];
    }
    fftwf_execute(s->inv);
    memmove(s->ola, s->ola + HOP, (NFFT - HOP) * sizeof(float));
    memset(s->ola + NFFT - HOP, 0, HOP * sizeof(float));
    const float norm = 1.0f / (float)NFFT;
    for (int i = 0; i < NFFT; i++) s->ola[i] += s->time[i][0] * norm * s->window[i];
    memcpy(hop, s->ola, HOP * sizeof(float));
}

static float *load_f32(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long bytes = ftell(f);
    fseek(f, 0, SEEK_SET);
    *n = (size_t)bytes / 4;
    float *s = malloc(*n * sizeof(float));
    if (!s || fread(s, 4, *n, f) != *n) {
        free(s);
        fclose(f);
        return NULL;
    }
    fclose(f);
    return s;
}

static int store_f32(const char *path, const float *s, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t w = fwrite(s, 4, n, f);
    fclose(f);
    return w == n ? 0 : -1;
}

static double cpu_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static uint64_t nsec_between(struct timespec a, struct timespec b) {
    return (uint64_t)(b.tv_sec - a.tv_sec) * 1000000000ull + (uint64_t)(b.tv_nsec - a.tv_nsec);
}

static uint64_t percentile(uint64_t *v, size_t n) {
    if (!n) return 0;
    for (size_t i = 1; i < n; i++) {
        uint64_t x = v[i];
        size_t j = i;
        while (j > 0 && v[j - 1] > x) {
            v[j] = v[j - 1];
            j--;
        }
        v[j] = x;
    }
    return v[(size_t)(0.99 * (n - 1))];
}

static int run_clip(dpdfnet_model *model, float *state, size_t state_n, Stft *stft,
                    const float *in, float *out, size_t n, int time_it,
                    uint64_t *hop_p99, uint64_t *model_p99) {
    size_t hops = n / HOP;
    uint64_t *hop_t = calloc(hops, sizeof(uint64_t));
    uint64_t *model_t = calloc(hops, sizeof(uint64_t));
    float *next = malloc(state_n * sizeof(float));
    float spec[SPEC], spec_e[SPEC];
    if (!hop_t || !model_t || !next) return -1;
    size_t kept = 0;
    for (size_t i = 0; i < hops; i++) {
        struct timespec a, b, c;
        clock_gettime(CLOCK_MONOTONIC, &a);
        analyze(stft, in + i * HOP, spec);
        clock_gettime(CLOCK_MONOTONIC, &b);
        if (dpdfnet_process(model, spec, state, spec_e, next) != 0) {
            fprintf(stderr, "dpdfnet_process failed\n");
            return -1;
        }
        memcpy(state, next, state_n * sizeof(float));
        clock_gettime(CLOCK_MONOTONIC, &c);
        synthesize(stft, spec_e, out + i * HOP);
        struct timespec d;
        clock_gettime(CLOCK_MONOTONIC, &d);
        if (time_it && i >= 20) {
            hop_t[kept] = nsec_between(a, d);
            model_t[kept] = nsec_between(b, c);
            kept++;
        }
    }
    if (time_it) {
        *hop_p99 = percentile(hop_t, kept);
        *model_p99 = percentile(model_t, kept);
    }
    free(hop_t);
    free(model_t);
    free(next);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(stderr, "usage: %s 2|8 weights.f32 far impulse far_out impulse_out\n", argv[0]);
        return 2;
    }
    int id = atoi(argv[1]);
    dpdfnet_model_id mid = id == 2 ? DPDFNET_MODEL_2 : DPDFNET_MODEL_8;
    const dpdfnet_model_info *info = dpdfnet_get_model_info(mid);
    if (!info) return 1;
    fprintf(stderr, "model %s rate %u hop %u weights %zu sha %s cpu %d\n",
            info->name, info->sample_rate, info->hop_samples, info->weight_floats,
            info->weights_sha256, dpdfnet_cpu_supported());
    size_t nw = 0;
    float *weights = load_f32(argv[2], &nw);
    if (!weights || nw != info->weight_floats) {
        fprintf(stderr, "weight count %zu expected %zu\n", nw, info->weight_floats);
        return 1;
    }
    dpdfnet_model *model = dpdfnet_create(mid, weights, nw);
    free(weights);
    if (!model) {
        fprintf(stderr, "dpdfnet_create failed\n");
        return 1;
    }
    float *state = calloc(info->state_floats, sizeof(float));
    if (dpdfnet_init_state(mid, state) != 0) return 1;
    size_t nfar = 0, nimp = 0;
    float *far = load_f32(argv[3], &nfar);
    float *imp = load_f32(argv[4], &nimp);
    float *far_out = calloc(nfar, sizeof(float));
    float *imp_out = calloc(nimp, sizeof(float));
    if (!far || !imp || !far_out || !imp_out) return 1;
    Stft stft;
    stft_init(&stft);
    uint64_t hop_p99 = 0, model_p99 = 0;
    if (run_clip(model, state, info->state_floats, &stft, far, far_out, nfar, 1, &hop_p99, &model_p99) != 0)
        return 1;
    dpdfnet_destroy(model);
    model = NULL;
    /* Impulse uses a fresh model and a fresh STFT so the tail is not the far clip's state. */
    {
        size_t nw2 = 0;
        float *w2 = load_f32(argv[2], &nw2);
        model = dpdfnet_create(mid, w2, nw2);
        free(w2);
        if (!model) return 1;
        if (dpdfnet_init_state(mid, state) != 0) return 1;
        Stft stft_i;
        stft_init(&stft_i);
        uint64_t a = 0, b = 0;
        if (run_clip(model, state, info->state_floats, &stft_i, imp, imp_out, nimp, 0, &a, &b) != 0)
            return 1;
    }
    if (store_f32(argv[5], far_out, nfar) || store_f32(argv[6], imp_out, nimp)) return 1;

    double c0 = cpu_seconds();
    size_t audio = 0;
    struct timespec wall0;
    clock_gettime(CLOCK_MONOTONIC, &wall0);
    for (;;) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double wall = (double)(now.tv_sec - wall0.tv_sec) + (double)(now.tv_nsec - wall0.tv_nsec) / 1e9;
        if (wall >= 1.2 && audio > 0) break;
        uint64_t a = 0, b = 0;
        if (run_clip(model, state, info->state_floats, &stft, far, far_out, nfar, 0, &a, &b) != 0)
            return 1;
        audio += nfar / HOP * HOP;
    }
    double c1 = cpu_seconds();
    printf("CPU_SECONDS %.6f\nP99_NS %llu\nMODEL_P99_NS %llu\nBLOCK %d\nRATE 48000\nAUDIO_SAMPLES %zu\n",
           c1 - c0, (unsigned long long)hop_p99, (unsigned long long)model_p99, HOP, audio);
    return 0;
}
