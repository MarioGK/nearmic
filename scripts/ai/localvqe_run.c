#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "localvqe_api.h"

#define HOP 256

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

static int process_plain(localvqe_ctx_t ctx, const float *in, float *out, size_t n) {
    float ref[HOP];
    memset(ref, 0, sizeof ref);
    for (size_t i = 0; i < n / HOP; i++) {
        if (localvqe_process_frame_f32(ctx, in + i * HOP, ref, HOP, out + i * HOP) != 0) return -1;
    }
    return 0;
}

static int process(localvqe_ctx_t ctx, const float *in, float *out, size_t n, uint64_t *p99_ns) {
    size_t frames = n / HOP;
    uint64_t *times = calloc(frames, sizeof(uint64_t));
    float *ref = calloc(HOP, sizeof(float));
    if (!times || !ref) return -1;
    for (size_t i = 0; i < frames; i++) {
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        int rc = localvqe_process_frame_f32(ctx, in + i * HOP, ref, HOP, out + i * HOP);
        clock_gettime(CLOCK_MONOTONIC, &b);
        if (rc != 0) {
            fprintf(stderr, "localvqe frame failed: %s\n", localvqe_last_error(ctx));
            return -1;
        }
        times[i] = (uint64_t)(b.tv_sec - a.tv_sec) * 1000000000ull + (uint64_t)(b.tv_nsec - a.tv_nsec);
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
    free(ref);
    return 0;
}

static double cpu_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static localvqe_ctx_t open_model(const char *model) {
    localvqe_options_t opts = localvqe_options_new();
    if (!opts) return 0;
    if (localvqe_options_set_model_path(opts, model) != 0) return 0;
    if (localvqe_options_set_backend(opts, "CPU") != 0) return 0;
    if (localvqe_options_set_threads(opts, 1) != 0) return 0;
    localvqe_ctx_t ctx = localvqe_new_with_options(opts);
    localvqe_options_free(opts);
    return ctx;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s model.gguf far16 impulse16 far_out impulse_out\n", argv[0]);
        return 2;
    }
    size_t nfar = 0, nimp = 0;
    float *far = load_f32(argv[2], &nfar);
    float *imp = load_f32(argv[3], &nimp);
    if (!far || !imp) return 1;
    float *far_out = calloc(nfar, 4);
    float *imp_out = calloc(nimp, 4);
    localvqe_ctx_t ctx = open_model(argv[1]);
    if (!ctx) {
        fprintf(stderr, "localvqe open failed\n");
        return 1;
    }
    uint64_t p99 = 0;
    if (process(ctx, far, far_out, nfar, &p99) != 0) return 1;
    localvqe_reset(ctx);
    uint64_t ignore = 0;
    if (process(ctx, imp, imp_out, nimp, &ignore) != 0) return 1;
    localvqe_free(ctx);
    if (store_f32(argv[4], far_out, nfar) || store_f32(argv[5], imp_out, nimp)) return 1;

    ctx = open_model(argv[1]);
    if (!ctx) return 1;
    double c0 = cpu_seconds();
    size_t audio = 0;
    struct timespec wall0;
    clock_gettime(CLOCK_MONOTONIC, &wall0);
    for (;;) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double wall = (double)(now.tv_sec - wall0.tv_sec) + (double)(now.tv_nsec - wall0.tv_nsec) / 1e9;
        if (wall >= 1.2) break;
        if (process_plain(ctx, far, far_out, nfar) != 0) return 1;
        audio += nfar / HOP * HOP;
    }
    double c1 = cpu_seconds();
    localvqe_free(ctx);
    printf("CPU_SECONDS %.6f\nP99_NS %llu\nBLOCK %d\nRATE 16000\nAUDIO_SAMPLES %zu\n",
           c1 - c0, (unsigned long long)p99, HOP, audio);
    return 0;
}
