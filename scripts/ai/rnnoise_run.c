#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "rnnoise.h"

#define FRAME 480

static float *load_f32(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long bytes = ftell(f);
    fseek(f, 0, SEEK_SET);
    *n = (size_t)bytes / 4;
    float *s = malloc(*n * sizeof(float));
    if (fread(s, 4, *n, f) != *n) {
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

static void process_plain(DenoiseState *st, const float *in, float *out, size_t n) {
    for (size_t i = 0; i < n / FRAME; i++) {
        float x[FRAME];
        for (int k = 0; k < FRAME; k++) x[k] = in[i * FRAME + k] * 32768.0f;
        rnnoise_process_frame(st, x, x);
        for (int k = 0; k < FRAME; k++) out[i * FRAME + k] = x[k] / 32768.0f;
    }
}

static void process(DenoiseState *st, const float *in, float *out, size_t n, uint64_t *p99_ns) {
    size_t frames = n / FRAME;
    uint64_t *times = calloc(frames, sizeof(uint64_t));
    for (size_t i = 0; i < frames; i++) {
        float x[FRAME];
        for (int k = 0; k < FRAME; k++) x[k] = in[i * FRAME + k] * 32768.0f;
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        rnnoise_process_frame(st, x, x);
        clock_gettime(CLOCK_MONOTONIC, &b);
        times[i] = (uint64_t)(b.tv_sec - a.tv_sec) * 1000000000ull + (uint64_t)(b.tv_nsec - a.tv_nsec);
        for (int k = 0; k < FRAME; k++) out[i * FRAME + k] = x[k] / 32768.0f;
    }
    for (size_t i = 1; i < frames; i++) {
        uint64_t v = times[i];
        size_t j = i;
        while (j > 0 && times[j - 1] > v) {
            times[j] = times[j - 1];
            j--;
        }
        times[j] = v;
    }
    *p99_ns = frames ? times[(size_t)(0.99 * (frames - 1))] : 0;
    free(times);
}

static double cpu_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s far_in impulse_in far_out impulse_out\n", argv[0]);
        return 2;
    }
    size_t nfar = 0, nimp = 0;
    float *far = load_f32(argv[1], &nfar);
    float *imp = load_f32(argv[2], &nimp);
    if (!far || !imp) return 1;
    float *far_out = calloc(nfar, 4);
    float *imp_out = calloc(nimp, 4);
    DenoiseState *st = rnnoise_create(NULL);
    if (!st) {
        fprintf(stderr, "rnnoise_create failed\n");
        return 1;
    }
    uint64_t p99 = 0;
    process(st, far, far_out, nfar, &p99);
    uint64_t ignore = 0;
    process(st, imp, imp_out, nimp, &ignore);
    rnnoise_destroy(st);
    if (store_f32(argv[3], far_out, nfar) || store_f32(argv[4], imp_out, nimp)) return 1;

    DenoiseState *bench = rnnoise_create(NULL);
    double c0 = cpu_seconds();
    size_t audio = 0;
    struct timespec wall0;
    clock_gettime(CLOCK_MONOTONIC, &wall0);
    for (;;) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double wall = (double)(now.tv_sec - wall0.tv_sec) + (double)(now.tv_nsec - wall0.tv_nsec) / 1e9;
        if (wall >= 1.2) break;
        process_plain(bench, far, far_out, nfar);
        audio += nfar / FRAME * FRAME;
    }
    double c1 = cpu_seconds();
    rnnoise_destroy(bench);
    printf("CPU_SECONDS %.6f\nP99_NS %llu\nBLOCK %d\nRATE 48000\nAUDIO_SAMPLES %zu\n",
           c1 - c0, (unsigned long long)p99, FRAME, audio);
    return 0;
}
