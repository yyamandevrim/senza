#include "input_latency.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t g_lat_lock = PTHREAD_MUTEX_INITIALIZER;
static float g_samples[SZ_LATENCY_CAPACITY];
static uint32_t g_count = 0;
static uint32_t g_next = 0;
static uint64_t g_total = 0;
static _Atomic uint64_t g_pending_ns = 0;

void sz_latency_reset(void) {
    pthread_mutex_lock(&g_lat_lock);
    g_count = g_next = 0;
    g_total = 0;
    pthread_mutex_unlock(&g_lat_lock);
    atomic_store(&g_pending_ns, 0);
}

void sz_latency_mark_input(uint64_t event_ns) {
    if (event_ns == 0) return;
    uint64_t expected = 0;
    atomic_compare_exchange_strong(&g_pending_ns, &expected, event_ns);
}

void sz_latency_add_ms(float ms) {
    if (!(ms >= 0.0f) || ms > 1000.0f) return; /* NaN, clock skew or a stalled app: not input latency */
    pthread_mutex_lock(&g_lat_lock);
    g_samples[g_next] = ms;
    g_next = (g_next + 1) % SZ_LATENCY_CAPACITY;
    if (g_count < SZ_LATENCY_CAPACITY) g_count++;
    g_total++;
    pthread_mutex_unlock(&g_lat_lock);
}

void sz_latency_report_built(uint64_t now_ns) {
    uint64_t pending = atomic_exchange(&g_pending_ns, 0);
    if (pending == 0 || now_ns < pending) return;
    sz_latency_add_ms((float)((double)(now_ns - pending) / 1e6));
}

static int cmp_float(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

static float pct(const float *sorted, uint32_t n, float q) {
    uint32_t idx = (uint32_t)(q * (float)(n - 1) + 0.5f);
    return sorted[idx < n ? idx : n - 1];
}

bool sz_latency_summary(SzLatencySummary *out) {
    memset(out, 0, sizeof(*out));
    pthread_mutex_lock(&g_lat_lock);
    uint32_t n = g_count;
    float *copy = n ? malloc(sizeof(float) * n) : NULL;
    if (copy) memcpy(copy, g_samples, sizeof(float) * n);
    out->total = g_total;
    pthread_mutex_unlock(&g_lat_lock);
    if (!copy) return false;
    qsort(copy, n, sizeof(float), cmp_float);
    out->count = n;
    out->p50_ms = pct(copy, n, 0.50f);
    out->p95_ms = pct(copy, n, 0.95f);
    out->p99_ms = pct(copy, n, 0.99f);
    out->max_ms = copy[n - 1];
    free(copy);
    return true;
}

bool sz_latency_write_json(const char *path) {
    SzLatencySummary s;
    if (!path || !path[0] || !sz_latency_summary(&s)) return false;
    char tmp[1024];
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) return false;
    FILE *fp = fopen(tmp, "w");
    if (!fp) return false;
    fprintf(fp, "{\"count\": %u, \"total\": %llu, \"p50_ms\": %.2f, \"p95_ms\": %.2f, \"p99_ms\": %.2f, \"max_ms\": %.2f}\n",
            s.count, (unsigned long long)s.total, s.p50_ms, s.p95_ms, s.p99_ms, s.max_ms);
    bool ok = fclose(fp) == 0;
    return ok && rename(tmp, path) == 0;
}
