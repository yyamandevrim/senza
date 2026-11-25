/* Mid-session connection quality watch: pure state machine, no I/O (unit-tested in test_mapper_core.c). */
#ifndef SENZA_NET_QUALITY_H
#define SENZA_NET_QUALITY_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    SZ_QUALITY_NONE = 0,      /* nothing to tell the player */
    SZ_QUALITY_DEGRADED = 1,  /* sustained bad samples: suggest a lower stream preset */
    SZ_QUALITY_RECOVERED = 2, /* back to good after a warning */
} SzQualityEvent;

typedef struct {
    int bad_streak;
    int good_streak;
    bool degraded;
    uint64_t last_warn_ms;
} SzQualityState;

#define SZ_QUALITY_BAD_SAMPLES 2
#define SZ_QUALITY_GOOD_SAMPLES 3
#define SZ_QUALITY_WARN_COOLDOWN_MS 180000ULL

bool sz_quality_is_bad(double avg_ms, double jitter_ms, double loss_pct, bool reachable);
bool sz_quality_is_good(double avg_ms, double jitter_ms, double loss_pct, bool reachable);
SzQualityEvent sz_quality_step(SzQualityState *st, double avg_ms, double jitter_ms, double loss_pct, bool reachable,
                               uint64_t now_ms);

#endif
