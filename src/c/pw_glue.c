#define _GNU_SOURCE
#include "pw_glue.h"

#include <dlfcn.h>
#include <errno.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/audio/raw.h>
#include <pipewire/pipewire.h>
#include <pipewire/thread-loop.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define RING 16384
#define RING_MASK (RING - 1)
/* The ring is the queue between the DSP worker and the playback callback, so
   whatever it holds is added latency on the microphone the host sees. Keep
   ~16 ms of reserve. The graph runs at 128 frames and the UAC2 ALSA periods
   are 128, so this is six callbacks of slack: four was measurably too tight
   under CFS on the RK3399. 64 ms (the original value) was long enough to be
   audible as lag between talking and the host hearing it. */
#define OUT_PREFILL 768
#define REFILL 768

struct Api {
    void (*pw_init)(int *, char ***);
    void (*pw_deinit)(void);
    struct pw_thread_loop *(*pw_thread_loop_new)(const char *, const struct spa_dict *);
    void (*pw_thread_loop_destroy)(struct pw_thread_loop *);
    struct pw_loop *(*pw_thread_loop_get_loop)(struct pw_thread_loop *);
    int (*pw_thread_loop_start)(struct pw_thread_loop *);
    void (*pw_thread_loop_stop)(struct pw_thread_loop *);
    void (*pw_thread_loop_lock)(struct pw_thread_loop *);
    void (*pw_thread_loop_unlock)(struct pw_thread_loop *);
    struct pw_context *(*pw_context_new)(struct pw_loop *, struct pw_properties *, size_t);
    void (*pw_context_destroy)(struct pw_context *);
    struct pw_core *(*pw_context_connect)(struct pw_context *, struct pw_properties *, size_t);
    int (*pw_core_disconnect)(struct pw_core *);
    struct pw_properties *(*pw_properties_new)(const char *, ...);
    int (*pw_properties_set)(struct pw_properties *, const char *, const char *);
    void (*pw_properties_free)(struct pw_properties *);
    struct pw_stream *(*pw_stream_new_simple)(struct pw_loop *, const char *, struct pw_properties *, const struct pw_stream_events *, void *);
    int (*pw_stream_connect)(struct pw_stream *, enum pw_direction, uint32_t, enum pw_stream_flags, const struct spa_pod **, uint32_t);
    void (*pw_stream_destroy)(struct pw_stream *);
    int (*pw_stream_update_params)(struct pw_stream *, const struct spa_pod **, uint32_t);
    struct pw_buffer *(*pw_stream_dequeue_buffer)(struct pw_stream *);
    int (*pw_stream_queue_buffer)(struct pw_stream *, struct pw_buffer *);
    int (*pw_stream_set_active)(struct pw_stream *, bool);
    uint32_t (*pw_stream_get_node_id)(struct pw_stream *);
};

static struct Api api;
static void *lib;
static char errbuf[256];
static struct pw_thread_loop *loop;
static struct pw_context *context;
static struct pw_core *core;
static struct pw_stream *capture;
static struct pw_stream *source;
static struct pw_stream *listen;
static atomic_uint source_live;
static atomic_ullong underrun_count;
static atomic_uint max_request;
static atomic_ullong missing_total;
static atomic_uint refill_request;
static atomic_ullong in_total;
static atomic_ullong out_total;
static atomic_ullong played_total;
static atomic_uint node_id;
static int listen_wanted;

struct Ring {
    float samples[RING];
    atomic_uint r;
    atomic_uint w;
};

static struct Ring in_ring;
static struct Ring out_ring;
static struct Ring listen_ring;

static uint32_t ring_count(struct Ring *ring) {
    uint32_t w = atomic_load_explicit(&ring->w, memory_order_acquire);
    uint32_t r = atomic_load_explicit(&ring->r, memory_order_relaxed);
    return (w - r) & RING_MASK;
}

static uint32_t ring_write(struct Ring *ring, const float *src, uint32_t n) {
    uint32_t w = atomic_load_explicit(&ring->w, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&ring->r, memory_order_acquire);
    uint32_t used = (w - r) & RING_MASK;
    uint32_t space = RING_MASK - used;
    if (n > space) n = space;
    for (uint32_t i = 0; i < n; i++) ring->samples[(w + i) & RING_MASK] = src[i];
    atomic_store_explicit(&ring->w, (w + n) & RING_MASK, memory_order_release);
    return n;
}

static uint32_t ring_read(struct Ring *ring, float *dst, uint32_t n) {
    uint32_t r = atomic_load_explicit(&ring->r, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&ring->w, memory_order_acquire);
    uint32_t have = (w - r) & RING_MASK;
    if (n > have) n = have;
    for (uint32_t i = 0; i < n; i++) dst[i] = ring->samples[(r + i) & RING_MASK];
    atomic_store_explicit(&ring->r, (r + n) & RING_MASK, memory_order_release);
    return n;
}

static int load_api(void) {
    const char *names[] = {"libpipewire-0.3.so.0", "libpipewire-0.3.so.2", "libpipewire-0.3.so", NULL};
    const char *tried = names[0];
    for (int i = 0; names[i]; i++) {
        tried = names[i];
        lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (lib) break;
    }
    if (!lib) {
        snprintf(errbuf, sizeof errbuf, "%s: %s", tried, dlerror());
        return -1;
    }
#define LOAD(name)                                                                 \
    do {                                                                           \
        api.name = dlsym(lib, #name);                                             \
        if (!api.name) {                                                           \
            snprintf(errbuf, sizeof errbuf, "missing symbol %s", #name);          \
            return -1;                                                             \
        }                                                                          \
    } while (0)
    LOAD(pw_init);
    LOAD(pw_deinit);
    LOAD(pw_thread_loop_new);
    LOAD(pw_thread_loop_destroy);
    LOAD(pw_thread_loop_get_loop);
    LOAD(pw_thread_loop_start);
    LOAD(pw_thread_loop_stop);
    LOAD(pw_thread_loop_lock);
    LOAD(pw_thread_loop_unlock);
    LOAD(pw_context_new);
    LOAD(pw_context_destroy);
    LOAD(pw_context_connect);
    LOAD(pw_core_disconnect);
    LOAD(pw_properties_new);
    LOAD(pw_properties_set);
    LOAD(pw_properties_free);
    LOAD(pw_stream_new_simple);
    LOAD(pw_stream_connect);
    LOAD(pw_stream_destroy);
    LOAD(pw_stream_update_params);
    LOAD(pw_stream_dequeue_buffer);
    LOAD(pw_stream_queue_buffer);
    LOAD(pw_stream_set_active);
    LOAD(pw_stream_get_node_id);
#undef LOAD
    return 0;
}

static const struct spa_pod *audio_format(struct spa_pod_builder *b) {
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
        .format = SPA_AUDIO_FORMAT_F32,
        .rate = 48000,
        .channels = 1,
        .position = {SPA_AUDIO_CHANNEL_MONO});
    return spa_format_audio_raw_build(b, SPA_PARAM_EnumFormat, &info);
}

static void negotiate(struct pw_stream *stream, uint32_t id, const struct spa_pod *param) {
    if (id != SPA_PARAM_Format || param == NULL) return;
    struct spa_audio_info_raw info;
    if (spa_format_audio_raw_parse(param, &info) < 0) return;
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof buffer);
    const struct spa_pod *params[1];
    int stride = (int)(sizeof(float) * (info.channels ? info.channels : 1));
    /* The graph quantum moves. A buffer smaller than the quantum makes every
       cycle look like an underrun and holds the last sample. */
    int min_size = 64 * stride;
    int def_size = 2048 * stride;
    int max_size = 8192 * stride;
    params[0] = spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(8, 2, 32),
        SPA_PARAM_BUFFERS_size, SPA_POD_CHOICE_RANGE_Int(def_size, min_size, max_size),
        SPA_PARAM_BUFFERS_stride, SPA_POD_Int(stride));
    api.pw_stream_update_params(stream, params, 1);
}

static void on_capture_param(void *data, uint32_t id, const struct spa_pod *param) {
    (void)data;
    negotiate(capture, id, param);
}

static void on_source_param(void *data, uint32_t id, const struct spa_pod *param) {
    (void)data;
    negotiate(source, id, param);
}

static void on_listen_param(void *data, uint32_t id, const struct spa_pod *param) {
    (void)data;
    negotiate(listen, id, param);
}

static void on_capture_process(void *data) {
    (void)data;
    struct pw_buffer *b = api.pw_stream_dequeue_buffer(capture);
    if (!b) return;
    struct spa_data *d = &b->buffer->datas[0];
    if (d->data && d->chunk && d->chunk->size) {
        uint32_t n = d->chunk->size / (uint32_t)sizeof(float);
        const float *src = SPA_PTROFF(d->data, d->chunk->offset, float);
        ring_write(&in_ring, src, n);
    }
    api.pw_stream_queue_buffer(capture, b);
}

static void fill_output(struct pw_stream *stream, struct Ring *ring, int count_underrun) {
    struct pw_buffer *b = api.pw_stream_dequeue_buffer(stream);
    if (!b) return;
    struct spa_data *d = &b->buffer->datas[0];
    float *dst = d->data;
    if (!dst || !d->chunk) {
        api.pw_stream_queue_buffer(stream, b);
        return;
    }
    uint32_t max = d->maxsize / (uint32_t)sizeof(float);
    uint32_t n = b->requested ? (uint32_t)b->requested : max;
    if (n > max) n = max;
    if (n == 0) n = max;
    if (n > atomic_load_explicit(&max_request, memory_order_relaxed)) {
        atomic_store_explicit(&max_request, n, memory_order_relaxed);
    }
    uint32_t got = ring_read(ring, dst, n);
    if (count_underrun) atomic_fetch_add_explicit(&played_total, n, memory_order_relaxed);
    if (got < n) {
        if (count_underrun) {
            atomic_fetch_add_explicit(&underrun_count, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&missing_total, n - got, memory_order_relaxed);
            /* Ask the single ring writer (the DSP worker) to restore a small
               jitter reserve. Writing here would make the ring multi-producer. */
            atomic_store_explicit(&refill_request, REFILL, memory_order_release);
        }
        float fill = got ? dst[got - 1] : 0;
        for (uint32_t i = got; i < n; i++) dst[i] = fill;
    }
    d->chunk->offset = 0;
    d->chunk->stride = (int)sizeof(float);
    d->chunk->size = n * (uint32_t)sizeof(float);
    b->size = n;
    api.pw_stream_queue_buffer(stream, b);
}

static void on_source_process(void *data) {
    (void)data;
    fill_output(source, &out_ring, 1);
}

static void on_listen_process(void *data) {
    (void)data;
    fill_output(listen, &listen_ring, 0);
}

static void on_source_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)data;
    (void)old;
    if (error && state == PW_STREAM_STATE_ERROR) snprintf(errbuf, sizeof errbuf, "%s", error);
    int live = state == PW_STREAM_STATE_STREAMING;
    atomic_store_explicit(&source_live, live ? 1u : 0u, memory_order_release);
    if (capture) api.pw_stream_set_active(capture, live);
    uint32_t id = api.pw_stream_get_node_id(source);
    if (id) atomic_store_explicit(&node_id, id, memory_order_release);
}

static const struct pw_stream_events capture_events = {
    .version = PW_VERSION_STREAM_EVENTS,
    .param_changed = on_capture_param,
    .process = on_capture_process,
};

static const struct pw_stream_events source_events = {
    .version = PW_VERSION_STREAM_EVENTS,
    .param_changed = on_source_param,
    .process = on_source_process,
    .state_changed = on_source_state,
};

static const struct pw_stream_events listen_events = {
    .version = PW_VERSION_STREAM_EVENTS,
    .param_changed = on_listen_param,
    .process = on_listen_process,
};

int nm_pw_open(const char *target_node) {
    errbuf[0] = 0;
    if (load_api() != 0) return -1;
    int argc = 0;
    api.pw_init(&argc, NULL);
    loop = api.pw_thread_loop_new("nearmic", NULL);
    if (!loop) {
        snprintf(errbuf, sizeof errbuf, "pw_thread_loop_new failed");
        return -1;
    }
    context = api.pw_context_new(api.pw_thread_loop_get_loop(loop), NULL, 0);
    if (!context) {
        snprintf(errbuf, sizeof errbuf, "pw_context_new failed");
        return -1;
    }
    if (api.pw_thread_loop_start(loop) != 0) {
        snprintf(errbuf, sizeof errbuf, "pw_thread_loop_start failed");
        return -1;
    }
    api.pw_thread_loop_lock(loop);
    core = api.pw_context_connect(context, NULL, 0);
    if (!core) {
        snprintf(errbuf, sizeof errbuf, "PipeWire is not running (%s)", strerror(errno));
        api.pw_thread_loop_unlock(loop);
        return -1;
    }

    uint8_t cap_buf[1024];
    struct spa_pod_builder cap_b = SPA_POD_BUILDER_INIT(cap_buf, sizeof cap_buf);
    const struct spa_pod *cap_params[1] = {audio_format(&cap_b)};
    struct pw_properties *cap_props = api.pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "DSP",
        PW_KEY_NODE_NAME, "nearmic-capture",
        NULL);
    /* An empty target must not autoconnect. NearMic is often the default
       source, and autoconnect would feed the virtual mic back into itself. */
    int have_target = target_node && target_node[0] && strcmp(target_node, "nearmic") != 0;
    if (have_target) api.pw_properties_set(cap_props, PW_KEY_TARGET_OBJECT, target_node);
    enum pw_stream_flags cap_flags = PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_INACTIVE;
    if (have_target) cap_flags |= PW_STREAM_FLAG_AUTOCONNECT;
    capture = api.pw_stream_new_simple(api.pw_thread_loop_get_loop(loop), "nearmic-capture", cap_props, &capture_events, NULL);
    if (!capture || api.pw_stream_connect(capture, PW_DIRECTION_INPUT, PW_ID_ANY, cap_flags, cap_params, 1) != 0) {
        snprintf(errbuf, sizeof errbuf, "capture stream failed");
        api.pw_thread_loop_unlock(loop);
        return -1;
    }

    uint8_t src_buf[1024];
    struct spa_pod_builder src_b = SPA_POD_BUILDER_INIT(src_buf, sizeof src_buf);
    const struct spa_pod *src_params[1] = {audio_format(&src_b)};
    struct pw_properties *src_props = api.pw_properties_new(
        PW_KEY_MEDIA_CLASS, "Audio/Source",
        PW_KEY_NODE_NAME, "nearmic",
        PW_KEY_NODE_DESCRIPTION, "NearMic",
        PW_KEY_MEDIA_ROLE, "Communication",
        NULL);
    source = api.pw_stream_new_simple(api.pw_thread_loop_get_loop(loop), "NearMic", src_props, &source_events, NULL);
    if (!source || api.pw_stream_connect(source, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                                         PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
                                         src_params, 1) != 0) {
        snprintf(errbuf, sizeof errbuf, "virtual microphone stream failed");
        api.pw_thread_loop_unlock(loop);
        return -1;
    }

    uint8_t ls_buf[1024];
    struct spa_pod_builder ls_b = SPA_POD_BUILDER_INIT(ls_buf, sizeof ls_buf);
    const struct spa_pod *ls_params[1] = {audio_format(&ls_b)};
    struct pw_properties *ls_props = api.pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_ROLE, "Communication",
        PW_KEY_NODE_NAME, "nearmic-listen",
        NULL);
    listen = api.pw_stream_new_simple(api.pw_thread_loop_get_loop(loop), "nearmic-listen", ls_props, &listen_events, NULL);
    if (!listen || api.pw_stream_connect(listen, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                                         PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_INACTIVE,
                                         ls_params, 1) != 0) {
        snprintf(errbuf, sizeof errbuf, "listen stream failed");
        api.pw_thread_loop_unlock(loop);
        return -1;
    }
    api.pw_thread_loop_unlock(loop);
    {
        static const float silence[OUT_PREFILL] = {0};
        ring_write(&out_ring, silence, OUT_PREFILL);
    }
    return 0;
}

void nm_pw_close(void) {
    if (loop) api.pw_thread_loop_lock(loop);
    if (listen) api.pw_stream_destroy(listen);
    if (source) api.pw_stream_destroy(source);
    if (capture) api.pw_stream_destroy(capture);
    listen = source = capture = NULL;
    if (core) api.pw_core_disconnect(core);
    core = NULL;
    if (loop) api.pw_thread_loop_unlock(loop);
    if (loop) {
        api.pw_thread_loop_stop(loop);
        if (context) api.pw_context_destroy(context);
        context = NULL;
        api.pw_thread_loop_destroy(loop);
        loop = NULL;
    }
    if (api.pw_deinit) api.pw_deinit();
    if (lib) dlclose(lib);
    lib = NULL;
}

const char *nm_pw_last_error(void) { return errbuf; }

uint32_t nm_pw_node_id(void) { return atomic_load_explicit(&node_id, memory_order_acquire); }

uint32_t nm_in_read(float *dst, uint32_t n) { uint32_t got = ring_read(&in_ring, dst, n); atomic_fetch_add_explicit(&in_total, got, memory_order_relaxed); return got; }
uint32_t nm_out_write(const float *src, uint32_t n) { uint32_t put = ring_write(&out_ring, src, n); atomic_fetch_add_explicit(&out_total, put, memory_order_relaxed); return put; }
uint32_t nm_listen_write(const float *src, uint32_t n) { return ring_write(&listen_ring, src, n); }
int nm_source_streaming(void) { return atomic_load_explicit(&source_live, memory_order_acquire) ? 1 : 0; }

void nm_set_listen(int enabled) {
    listen_wanted = enabled;
    if (!loop || !listen) return;
    api.pw_thread_loop_lock(loop);
    api.pw_stream_set_active(listen, enabled);
    api.pw_thread_loop_unlock(loop);
}

uint64_t nm_underruns(void) { return atomic_load_explicit(&underrun_count, memory_order_relaxed); }

uint32_t nm_max_request(void) { return atomic_load_explicit(&max_request, memory_order_relaxed); }

uint64_t nm_missing(void) { return atomic_load_explicit(&missing_total, memory_order_relaxed); }

uint32_t nm_out_level(void) { return ring_count(&out_ring); }

uint64_t nm_in_total(void) { return atomic_load_explicit(&in_total, memory_order_relaxed); }
uint64_t nm_out_total(void) { return atomic_load_explicit(&out_total, memory_order_relaxed); }
uint64_t nm_played_total(void) { return atomic_load_explicit(&played_total, memory_order_relaxed); }

uint32_t nm_out_take_refill(void) {
    return atomic_exchange_explicit(&refill_request, 0, memory_order_acq_rel);
}

long nm_clk_tck(void) { return sysconf(_SC_CLK_TCK); }
