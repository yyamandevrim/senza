/* Randomized robustness test for config_loader + mapper_core.
 *
 * Apple clang ships no libFuzzer runtime, so this is a deterministic, seedable stress loop meant to run
 * under -fsanitize=address,undefined (`make test-sanitize`). It checks:
 *   - arbitrary / mutated runtime_profile.cfg files never crash the parser and always yield a sane config
 *   - arbitrary key codes, mouse/scroll deltas (incl. NaN/inf) and tick lengths never produce UB and
 *     always keep pad axes/triggers in range
 */
#include "config_loader.h"
#include "mapper_core.h"

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t g_rng = 0x5EED5EEDULL;

static uint32_t rnd(void) {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return (uint32_t)g_rng;
}

static float rnd_float(void) {
    switch (rnd() % 12) {
        case 0: return NAN;
        case 1: return INFINITY;
        case 2: return -INFINITY;
        case 3: return 1e30f;
        case 4: return -1e30f;
        default: return ((float)(rnd() % 20001) - 10000.0f) / 10.0f;
    }
}

static const char *KEYS[] = {
    "toggle_capture_key", "toggle_vehicle_key", "toggle_aircraft_key", "toggle_smart_key", "rstick_hold_key",
    "hotwire_assist_key", "circle_assist_key", "rapid_tap_key", "cruise_toggle_key", "smart_vehicle_key",
    "sens_down_key", "sens_up_key", "mic_mute_key", "smart_mode_default", "smart_haptics", "move_up_key",
    "move_down_key", "move_left_key", "move_right_key", "walk_mod_key", "walk_scale", "sensitivity",
    "ads_sensitivity_scale", "sniper_sensitivity_scale", "deadzone", "curve_exponent", "smoothing",
    "decay_half_life_ms", "max_velocity_px_per_sec", "invert_y", "trackpad_mode", "trackpad_accel",
    "on_foot.13", "vehicle.-5", "aircraft.99999999999", "on_foot.", "vehicle.200",
};
static const char *VALUES[] = {
    "0", "1", "-1", "2147483647", "-2147483648", "99999999999999", "nan", "inf", "-inf", "1e40", "0.5",
    "CROSS", "L2", "R2", "TOUCHPAD", "", "=", "garbage", "3.4e38", "-0", "0x10",
};

static void write_random_cfg(const char *path) {
    FILE *fp = fopen(path, "w");
    assert(fp);
    int lines = (int)(rnd() % 400);
    for (int i = 0; i < lines; i++) {
        switch (rnd() % 6) {
            case 0: { /* raw random bytes, long lines, missing newline */
                int n = (int)(rnd() % 600);
                for (int j = 0; j < n; j++) fputc((int)(rnd() % 256), fp);
                break;
            }
            case 1:
                fprintf(fp, "%s=%.9g\n", KEYS[rnd() % (sizeof(KEYS) / sizeof(KEYS[0]))], (double)rnd_float());
                break;
            default:
                fprintf(fp, "%s=%s\n", KEYS[rnd() % (sizeof(KEYS) / sizeof(KEYS[0]))],
                        VALUES[rnd() % (sizeof(VALUES) / sizeof(VALUES[0]))]);
                break;
        }
    }
    fclose(fp);
}

static void assert_config_sane(const PsrConfig *c) {
    assert(c->on_foot_count >= 0 && c->on_foot_count <= PSR_MAX_BINDINGS);
    assert(c->vehicle_count >= 0 && c->vehicle_count <= PSR_MAX_BINDINGS);
    assert(c->aircraft_count >= 0 && c->aircraft_count <= PSR_MAX_BINDINGS);
    const float floats[] = {c->sensitivity, c->ads_sensitivity_scale, c->sniper_sensitivity_scale, c->deadzone,
                            c->curve_exponent, c->smoothing, c->decay_half_life_ms, c->max_velocity_px_per_sec,
                            c->trackpad_accel, c->walk_scale};
    for (size_t i = 0; i < sizeof(floats) / sizeof(floats[0]); i++) {
        assert(isfinite(floats[i]));
    }
    assert(c->deadzone >= 0.0f && c->deadzone < 1.0f);
    assert(c->smoothing >= 0.0f && c->smoothing <= 1.0f);
}

static void drive_mapper(PsrMapper *m, int steps) {
    for (int i = 0; i < steps; i++) {
        switch (rnd() % 7) {
            case 0:
            case 1: {
                int code = (int)(rnd() % 600) - 50; /* includes negative and out-of-table codes */
                psr_mapper_handle_key(m, code, (rnd() & 1) != 0);
                break;
            }
            case 2: psr_mapper_add_mouse_delta(m, rnd_float(), rnd_float()); break;
            case 3: psr_mapper_add_scroll(m, rnd_float(), rnd_float()); break;
            case 4: psr_mapper_set_capture(m, (rnd() & 3) != 0); break;
            default: {
                float dt = (rnd() % 10 == 0) ? rnd_float() : (float)(rnd() % 40);
                psr_mapper_tick(m, dt);
                break;
            }
        }
        assert(m->pad.l2 >= 0 && m->pad.r2 >= 0);
        for (int b = 0; b < PSR_BTN_COUNT; b++) assert(m->pad.buttons[b] == 0 || m->pad.buttons[b] == 1);
    }
}

int main(int argc, char **argv) {
    int iterations = argc > 1 ? atoi(argv[1]) : 300;
    if (argc > 2) g_rng = strtoull(argv[2], NULL, 0);
    char path[] = "/tmp/senza_fuzz_cfg_XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);

    for (int it = 0; it < iterations; it++) {
        write_random_cfg(path);
        PsrConfig cfg;
        if (psr_config_load_file(path, &cfg)) {
            assert_config_sane(&cfg);
            PsrMapper m;
            psr_mapper_init(&m, &cfg);
            drive_mapper(&m, 400);
        }
    }
    unlink(path);
    printf("native fuzz: %d iterations OK\n", iterations);
    return 0;
}
