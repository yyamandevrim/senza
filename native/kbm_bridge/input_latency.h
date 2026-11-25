/* Input -> virtual controller report latency, collected per session (pure C, thread-safe, unit-tested). */
#ifndef SENZA_INPUT_LATENCY_H
#define SENZA_INPUT_LATENCY_H

#include <stdbool.h>
#include <stdint.h>

#define SZ_LATENCY_CAPACITY 8192

typedef struct {
    uint32_t count;   /* samples kept (ring, newest SZ_LATENCY_CAPACITY) */
    uint64_t total;   /* samples seen */
    float p50_ms;
    float p95_ms;
    float p99_ms;
    float max_ms;
} SzLatencySummary;

void sz_latency_reset(void);
/* Record that an input event happened at `event_ns` (monotonic ns); the earliest unreported one wins. */
void sz_latency_mark_input(uint64_t event_ns);
/* Called when a controller report is built at `now_ns`; closes the pending input, if any. */
void sz_latency_report_built(uint64_t now_ns);
void sz_latency_add_ms(float ms);
bool sz_latency_summary(SzLatencySummary *out);
/* Write {"count":..,"p50_ms":..} to `path`; returns false when there are no samples or on I/O error. */
bool sz_latency_write_json(const char *path);

#endif
