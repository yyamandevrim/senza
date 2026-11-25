#include "net_quality.h"

bool sz_quality_is_bad(double avg_ms, double jitter_ms, double loss_pct, bool reachable) {
    return !reachable || loss_pct >= 3.0 || jitter_ms >= 15.0 || avg_ms >= 90.0;
}

bool sz_quality_is_good(double avg_ms, double jitter_ms, double loss_pct, bool reachable) {
    return reachable && loss_pct < 1.0 && jitter_ms < 8.0 && avg_ms < 60.0;
}

SzQualityEvent sz_quality_step(SzQualityState *st, double avg_ms, double jitter_ms, double loss_pct, bool reachable,
                               uint64_t now_ms) {
    if (sz_quality_is_bad(avg_ms, jitter_ms, loss_pct, reachable)) {
        st->bad_streak++;
        st->good_streak = 0;
        bool cooled = st->last_warn_ms == 0 || now_ms - st->last_warn_ms >= SZ_QUALITY_WARN_COOLDOWN_MS;
        if (!st->degraded && st->bad_streak >= SZ_QUALITY_BAD_SAMPLES && cooled) {
            st->degraded = true;
            st->last_warn_ms = now_ms ? now_ms : 1;
            return SZ_QUALITY_DEGRADED;
        }
        return SZ_QUALITY_NONE;
    }
    st->bad_streak = 0;
    if (sz_quality_is_good(avg_ms, jitter_ms, loss_pct, reachable)) {
        st->good_streak++;
        if (st->degraded && st->good_streak >= SZ_QUALITY_GOOD_SAMPLES) {
            st->degraded = false;
            st->good_streak = 0;
            return SZ_QUALITY_RECOVERED;
        }
    } else {
        st->good_streak = 0;
    }
    return SZ_QUALITY_NONE;
}
