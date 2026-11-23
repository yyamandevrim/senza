#ifndef DUALMAC_MACOS_CAPTURE_H
#define DUALMAC_MACOS_CAPTURE_H

#include "mapper_core.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Starts macOS CGEventTap capture thread + app-focus observer. */
bool psr_capture_start(PsrMapper *mapper);

/* Stops capture and guarantees cursor is re-associated and visible. */
void psr_capture_stop(void);

typedef struct {
    uint8_t rumble_right;   /* High-frequency motor (0..255) */
    uint8_t rumble_left;    /* Low-frequency heavy motor (0..255) */
    bool has_lightbar;
    uint8_t led_r;
    uint8_t led_g;
    uint8_t led_b;
    uint8_t r2_effect_mode;
    uint8_t l2_effect_mode;
} PsrDualSenseFeedback;

/* Thread-safe tick + snapshot of current DualSense pad state. */
void psr_capture_sample_state(float dt_ms, PsrPadState *out_state);

/* Thread-safe bridge for PS5 DualSense Output Report (0x02) -> MacBook Haptics & HUD accent. */
void psr_capture_on_dualsense_feedback(const PsrDualSenseFeedback *fb);

#ifdef __cplusplus
}
#endif

#endif /* DUALMAC_MACOS_CAPTURE_H */
