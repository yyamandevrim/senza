#ifndef SENZA_MAPPER_CORE_H
#define SENZA_MAPPER_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PSR_MAX_INPUT_CODE 256
#define PSR_MAX_BINDINGS 64

/* Synthetic mouse button codes (non-overlapping with macOS virtual keycodes 0..127) */
#define PSR_KEY_LMB 200
#define PSR_KEY_RMB 201
#define PSR_KEY_MMB 202
#define PSR_KEY_MOUSE4 203
#define PSR_KEY_MOUSE5 204

/* DualSense targets (0..20 align 1:1 with SDL_GameControllerButton) */
typedef enum {
    PSR_TARGET_NONE = -1,
    PSR_BTN_CROSS = 0,       /* SDL_CONTROLLER_BUTTON_A */
    PSR_BTN_CIRCLE = 1,      /* SDL_CONTROLLER_BUTTON_B */
    PSR_BTN_SQUARE = 2,      /* SDL_CONTROLLER_BUTTON_X */
    PSR_BTN_TRIANGLE = 3,    /* SDL_CONTROLLER_BUTTON_Y */
    PSR_BTN_SHARE = 4,       /* SDL_CONTROLLER_BUTTON_BACK */
    PSR_BTN_PS = 5,          /* SDL_CONTROLLER_BUTTON_GUIDE */
    PSR_BTN_OPTIONS = 6,     /* SDL_CONTROLLER_BUTTON_START */
    PSR_BTN_L3 = 7,          /* SDL_CONTROLLER_BUTTON_LEFTSTICK */
    PSR_BTN_R3 = 8,          /* SDL_CONTROLLER_BUTTON_RIGHTSTICK */
    PSR_BTN_L1 = 9,          /* SDL_CONTROLLER_BUTTON_LEFTSHOULDER */
    PSR_BTN_R1 = 10,         /* SDL_CONTROLLER_BUTTON_RIGHTSHOULDER */
    PSR_BTN_DPAD_UP = 11,
    PSR_BTN_DPAD_DOWN = 12,
    PSR_BTN_DPAD_LEFT = 13,
    PSR_BTN_DPAD_RIGHT = 14,
    PSR_BTN_MIC = 15,        /* SDL_CONTROLLER_BUTTON_MISC1 */
    PSR_BTN_TOUCHPAD = 20,   /* SDL_CONTROLLER_BUTTON_TOUCHPAD */
    PSR_BTN_COUNT = 21,

    /* Analog triggers */
    PSR_TRIGGER_L2 = 100,
    PSR_TRIGGER_R2 = 101
} PsrTarget;

typedef struct {
    int input_code;
    PsrTarget target;
} PsrBinding;

typedef struct {
    int toggle_capture_key;
    int toggle_vehicle_key;
    int toggle_aircraft_key;   /* Default: 31 ('O') - Aircraft / Helicopter mode */
    int toggle_smart_key;      /* Default: 17 ('T') */
    int rstick_hold_key;       /* Default: 16 ('Y') - sticky virtual R-stick while held */
    int hotwire_assist_key;    /* Default: 32 ('U') - bottom semi-circle (R) sweep while held */
    int circle_assist_key;     /* Default: 34 ('I') - 360-deg clockwise (R) rotation while held */
    int rapid_tap_key;         /* Default: 37 ('L') - 12.5Hz Cross rapid-tap (QTE/Bike/Swim) */
    int cruise_toggle_key;     /* Default: 30 (']') - auto-sprint / cruise throttle toggle */
    int smart_vehicle_key;     /* Default: 3  ('F') - Triangle + auto Vehicle/On-Foot in Smart Mode */
    int sens_down_key;         /* Default: 27 ('-') - live sensitivity -0.10 */
    int sens_up_key;           /* Default: 24 ('=') - live sensitivity +0.10 */
    int mic_mute_key;          /* Default: 33 ('[') - DualSense Mic Mute button */
    bool smart_mode_default;   /* Default: true */
    bool smart_haptics;        /* Default: true */

    int move_up_key;
    int move_down_key;
    int move_left_key;
    int move_right_key;
    int walk_mod_key;
    float walk_scale;

    float sensitivity;
    float ads_sensitivity_scale;
    float sniper_sensitivity_scale; /* Extra precision scale when holding L2 + walk_mod_key (Z) */
    float deadzone;
    float curve_exponent;
    float smoothing;
    float decay_half_life_ms;
    float max_velocity_px_per_sec;
    bool invert_y;
    bool trackpad_mode;
    float trackpad_accel;

    PsrBinding on_foot[PSR_MAX_BINDINGS];
    int on_foot_count;

    PsrBinding vehicle[PSR_MAX_BINDINGS];
    int vehicle_count;

    PsrBinding aircraft[PSR_MAX_BINDINGS];
    int aircraft_count;
} PsrConfig;

typedef struct {
    int16_t lx;
    int16_t ly;
    int16_t rx;
    int16_t ry;
    int16_t l2; /* 0..32767 */
    int16_t r2; /* 0..32767 */
    uint8_t buttons[PSR_BTN_COUNT];

    /* DualSense capacitive touchpad finger 0 (1920x1080) */
    bool touch_active;
    uint8_t touch_id;
    uint16_t touch_x;
    uint16_t touch_y;
} PsrPadState;

typedef struct {
    PsrConfig cfg;
    bool capture_active;
    bool vehicle_mode;
    bool aircraft_mode;
    bool smart_mode;
    bool cruise_active;
    bool keys_down[PSR_MAX_INPUT_CODE];

    float pending_dx;
    float pending_dy;
    float vel_x;
    float vel_y;
    float filt_vx;
    float filt_vy;
    float since_motion_ms;
    bool has_active_motion;

    /* Smart Mode runtime state */
    bool rstick_sticky_active;
    bool rstick_sticky_manual;   /* True when explicitly holding Y */
    bool hotwire_active;         /* True when holding U */
    bool circle_active;          /* True when holding I (360-deg R-stick) */
    bool rapid_tap_active;       /* True when holding L (12.5Hz Cross) */
    bool sens_dirty;             /* Set true on '-'/'=' live sensitivity change */
    bool mic_pressed_edge;       /* Set true on '[' keydown for UI toast */
    float sticky_rx;
    float sticky_ry;
    float hotwire_phase;
    float circle_phase;
    float rapid_tap_ms;
    float smooth_steer_lx;
    float smooth_pitch_ly;
    float wheel_hold_ms;         /* Hold timer for Tab (on-foot L1) / Q (vehicle Square) */
    float smart_vehicle_cooldown_ms;
    bool last_vehicle_was_auto;  /* True when last mode switch was triggered by Smart F */

    /* Synthetic DualSense Touchpad Swipe (from 2-finger Trackpad scroll) */
    bool swipe_active;
    uint8_t swipe_id;
    float swipe_elapsed_ms;
    float swipe_start_x;
    float swipe_start_y;
    float swipe_end_x;
    float swipe_end_y;
    float swipe_cooldown_ms;

    /* Synthetic D-Pad zoom pulse (2-finger scroll while aiming L2) & 1-tap Switch Shoulder (V while aiming) */
    int scroll_pulse_btn;
    float scroll_pulse_ms;
    float scroll_zoom_cooldown_ms;
    float shoulder_pulse_ms;

    PsrPadState pad;
} PsrMapper;

void psr_config_init_default(PsrConfig *cfg);
/* Replace non-finite floats with defaults, clamp tunables to safe ranges and binding counts to capacity. */
void psr_config_sanitize(PsrConfig *cfg);
void psr_mapper_init(PsrMapper *m, const PsrConfig *cfg);
void psr_mapper_reset_inputs(PsrMapper *m);

/* Returns true if the event was consumed by the mapper. */
bool psr_mapper_handle_key(PsrMapper *m, int input_code, bool is_down);
void psr_mapper_add_mouse_delta(PsrMapper *m, float dx, float dy);
/* Physical finger-motion deltas: +dx = swipe right, +dy = swipe up */
void psr_mapper_add_scroll(PsrMapper *m, float dx, float dy);
void psr_mapper_set_capture(PsrMapper *m, bool active);
void psr_mapper_set_vehicle_mode(PsrMapper *m, bool enabled);
void psr_mapper_set_aircraft_mode(PsrMapper *m, bool enabled);
void psr_mapper_set_smart_mode(PsrMapper *m, bool enabled);

/* Advances mouse velocity smoothing/decay and recomputes full DualSense state. */
void psr_mapper_tick(PsrMapper *m, float dt_ms);

#ifdef __cplusplus
}
#endif

#endif /* SENZA_MAPPER_CORE_H */
