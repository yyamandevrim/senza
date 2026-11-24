#include "mapper_core.h"

#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static float clampf(float v, float lo, float hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static int16_t float_to_axis(float v) {
    float c = clampf(v, -1.0f, 1.0f);
    if (c >= 0.0f) {
        return (int16_t)lroundf(c * 32767.0f);
    }
    return (int16_t)lroundf(c * 32768.0f);
}

static void add_binding(PsrBinding *list, int *count, int key, PsrTarget target) {
    if (*count >= PSR_MAX_BINDINGS) return;
    list[*count].input_code = key;
    list[*count].target = target;
    (*count)++;
}

void psr_config_init_default(PsrConfig *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    cfg->toggle_capture_key = 29;  /* '0' key (safe with Karabiner & no F-keys) */
    cfg->toggle_vehicle_key = 5;   /* G (manual override On-Foot <-> Vehicle) */
    cfg->toggle_aircraft_key = 31; /* O (Aircraft / Helicopter flight mode) */
    cfg->toggle_smart_key = 17;    /* T (Smart Mode ON/OFF) */
    cfg->rstick_hold_key = 16;     /* Y (hold for Sticky Virtual Right Stick) */
    cfg->hotwire_assist_key = 32;  /* U (hold for bottom semi-circle hotwire sweep) */
    cfg->circle_assist_key = 34;   /* I (hold for 360-deg clockwise (R) rotation) */
    cfg->rapid_tap_key = 37;       /* L (hold for 12.5Hz Cross rapid-tap QTE/Bike/Swim) */
    cfg->cruise_toggle_key = 30;   /* ] (toggle Auto-Sprint / Vehicle & Aircraft Cruise) */
    cfg->smart_vehicle_key = 3;    /* F (sends Triangle + auto-switches mode in Smart Mode) */
    cfg->sens_down_key = 27;       /* - (live sensitivity -0.10) */
    cfg->sens_up_key = 24;         /* = (live sensitivity +0.10) */
    cfg->mic_mute_key = 33;        /* [ (DualSense PS5 Mic Mute button) */
    cfg->smart_mode_default = true;
    cfg->smart_haptics = true;

    cfg->move_up_key = 13;         /* W */
    cfg->move_down_key = 1;        /* S */
    cfg->move_left_key = 0;        /* A */
    cfg->move_right_key = 2;       /* D */
    cfg->walk_mod_key = 6;         /* Z (Walk / Precision Sniper when holding L2) */
    cfg->walk_scale = 0.45f;

    cfg->sensitivity = 1.35f;
    cfg->ads_sensitivity_scale = 0.50f;
    cfg->sniper_sensitivity_scale = 0.45f;
    cfg->deadzone = 0.16f;
    cfg->curve_exponent = 0.85f;
    cfg->smoothing = 0.30f;
    cfg->decay_half_life_ms = 42.0f;
    cfg->max_velocity_px_per_sec = 2200.0f;
    cfg->invert_y = false;
    cfg->trackpad_mode = true;
    cfg->trackpad_accel = 1.45f;

    /* On-Foot GTA 6 Official Default layout (zero F-keys, Karabiner-safe) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, PSR_KEY_LMB, PSR_TRIGGER_R2); /* Trackpad click = Shoot */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 38, PSR_TRIGGER_R2);          /* J = Shoot alt */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 59, PSR_TRIGGER_L2);          /* LeftControl (CapsLock!) = Aim/Interact */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 40, PSR_TRIGGER_L2);          /* K = Aim alt */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 58, PSR_TRIGGER_L2);          /* LeftOption = Aim alt */
    add_binding(cfg->on_foot, &cfg->on_foot_count, PSR_KEY_RMB, PSR_TRIGGER_L2); /* Two-finger click = Aim alt */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 56, PSR_BTN_L3);              /* LeftShift = Run (L3) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 49, PSR_BTN_CROSS);           /* Space = Jump / Climb (X) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 36, PSR_BTN_CROSS);           /* Return = Menu Confirm (X) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 8, PSR_BTN_CIRCLE);           /* C = Crouch (O) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 51, PSR_BTN_CIRCLE);          /* Backspace = Menu Back (O) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 15, PSR_BTN_SQUARE);          /* R = Melee / Reload (Square) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 9, PSR_BTN_SQUARE);           /* V = Melee alt (Square) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 14, PSR_BTN_TRIANGLE);        /* E = Pure Interact (Triangle, no mode flip) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 3, PSR_BTN_TRIANGLE);         /* F = Enter/Exit Vehicle (Triangle + Smart Auto) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 12, PSR_BTN_R1);              /* Q = Cover (R1) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 48, PSR_BTN_L1);              /* Tab = Holster / Weapon Wheel (L1) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 46, PSR_BTN_TOUCHPAD);        /* M = Map (Touchpad) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 53, PSR_BTN_OPTIONS);         /* Escape = Pause (Options) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 11, PSR_BTN_R3);              /* B = Look Behind (R3) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 7, PSR_BTN_R3);               /* X = Look Behind alt (R3) */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 35, PSR_BTN_PS);              /* P = PS Button */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 45, PSR_BTN_SHARE);           /* N = Create / Share */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 126, PSR_BTN_DPAD_UP);        /* Up = Cellphone */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 125, PSR_BTN_DPAD_DOWN);      /* Down = Objective / Minimap */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 123, PSR_BTN_DPAD_LEFT);      /* Left = Detonate Explosives */
    add_binding(cfg->on_foot, &cfg->on_foot_count, 124, PSR_BTN_DPAD_RIGHT);     /* Right = Radio Controls */

    /* Vehicle GTA 6 MacBook defaults */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 13, PSR_TRIGGER_R2);          /* W = Gas */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 1, PSR_TRIGGER_L2);           /* S = Brake / Reverse */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 49, PSR_BTN_R1);              /* Space = Handbrake */
    add_binding(cfg->vehicle, &cfg->vehicle_count, PSR_KEY_LMB, PSR_BTN_L1);     /* Trackpad click = Drive-by fire */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 58, PSR_BTN_L1);              /* LeftOption = Drive-by fire */
    add_binding(cfg->vehicle, &cfg->vehicle_count, PSR_KEY_RMB, PSR_BTN_R1);
    add_binding(cfg->vehicle, &cfg->vehicle_count, 3, PSR_BTN_TRIANGLE);         /* F = Exit vehicle (+ Smart Auto) */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 14, PSR_BTN_L3);              /* E = Horn */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 12, PSR_BTN_SQUARE);          /* Q = Radio / Weapon wheel */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 15, PSR_BTN_CIRCLE);          /* R = Cinematic cam */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 48, PSR_BTN_L1);              /* Tab */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 46, PSR_BTN_TOUCHPAD);        /* M = Map */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 9, PSR_BTN_TOUCHPAD);         /* V = Map / Camera */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 8, PSR_BTN_R3);               /* C = Look behind */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 53, PSR_BTN_OPTIONS);         /* Escape = Pause */
    add_binding(cfg->vehicle, &cfg->vehicle_count, 35, PSR_BTN_PS);              /* P = PS Button */

    /* Aircraft / Helicopter GTA 6 MacBook defaults (W/S=Throttle, A/D=Roll, Up/Down or Shift/C=Pitch, Q/E=Rudder) */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 13, PSR_TRIGGER_R2);        /* W = Throttle Up / Ascend */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 1, PSR_TRIGGER_L2);         /* S = Airbrake / Descend */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 12, PSR_BTN_L1);            /* Q = Rudder Left */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 14, PSR_BTN_R1);            /* E = Rudder Right */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 123, PSR_BTN_L1);           /* Left = Rudder Left alt */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 124, PSR_BTN_R1);           /* Right = Rudder Right alt */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 49, PSR_BTN_CROSS);         /* Space = Fire Weapons */
    add_binding(cfg->aircraft, &cfg->aircraft_count, PSR_KEY_LMB, PSR_BTN_CROSS);/* Trackpad click = Fire */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 48, PSR_BTN_SQUARE);        /* Tab = Cycle Weapons */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 59, PSR_BTN_SQUARE);        /* CapsLock = Cycle Weapons */
    add_binding(cfg->aircraft, &cfg->aircraft_count, PSR_KEY_RMB, PSR_BTN_SQUARE);
    add_binding(cfg->aircraft, &cfg->aircraft_count, 15, PSR_BTN_L3);            /* R = Landing Gear */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 3, PSR_BTN_TRIANGLE);       /* F = Exit / Bail Out */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 11, PSR_BTN_R3);            /* B = Look Behind */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 7, PSR_BTN_R3);             /* X = Look Behind alt */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 46, PSR_BTN_TOUCHPAD);      /* M = Map */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 9, PSR_BTN_TOUCHPAD);       /* V = Camera / Map */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 53, PSR_BTN_OPTIONS);       /* Escape = Pause */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 35, PSR_BTN_PS);            /* P = PS Button */
    add_binding(cfg->aircraft, &cfg->aircraft_count, 45, PSR_BTN_SHARE);         /* N = Share */
}

void psr_mapper_init(PsrMapper *m, const PsrConfig *cfg) {
    memset(m, 0, sizeof(*m));
    if (cfg) {
        m->cfg = *cfg;
    } else {
        psr_config_init_default(&m->cfg);
    }
    m->capture_active = false;
    m->vehicle_mode = false;
    m->aircraft_mode = false;
    m->smart_mode = m->cfg.smart_mode_default;
    m->scroll_pulse_btn = -1;
}

void psr_mapper_reset_inputs(PsrMapper *m) {
    memset(m->keys_down, 0, sizeof(m->keys_down));
    m->pending_dx = 0.0f;
    m->pending_dy = 0.0f;
    m->vel_x = 0.0f;
    m->vel_y = 0.0f;
    m->filt_vx = 0.0f;
    m->filt_vy = 0.0f;
    m->since_motion_ms = 0.0f;
    m->has_active_motion = false;
    m->cruise_active = false;
    m->rstick_sticky_active = false;
    m->rstick_sticky_manual = false;
    m->hotwire_active = false;
    m->circle_active = false;
    m->rapid_tap_active = false;
    m->sticky_rx = 0.0f;
    m->sticky_ry = 0.0f;
    m->hotwire_phase = 0.0f;
    m->circle_phase = 0.0f;
    m->rapid_tap_ms = 0.0f;
    m->smooth_steer_lx = 0.0f;
    m->smooth_pitch_ly = 0.0f;
    m->wheel_hold_ms = 0.0f;
    m->swipe_active = false;
    m->swipe_elapsed_ms = 0.0f;
    m->scroll_pulse_btn = -1;
    m->scroll_pulse_ms = 0.0f;
    memset(&m->pad, 0, sizeof(m->pad));
}

void psr_mapper_set_capture(PsrMapper *m, bool active) {
    if (m->capture_active == active) return;
    m->capture_active = active;
    if (!active) {
        psr_mapper_reset_inputs(m);
    }
}

void psr_mapper_set_vehicle_mode(PsrMapper *m, bool enabled) {
    if (m->vehicle_mode == enabled && (!enabled || !m->aircraft_mode)) return;
    m->vehicle_mode = enabled;
    if (enabled) {
        m->aircraft_mode = false;
    }
    m->cruise_active = false;
    m->smooth_steer_lx = 0.0f;
    m->smooth_pitch_ly = 0.0f;
    m->wheel_hold_ms = 0.0f;
}

void psr_mapper_set_aircraft_mode(PsrMapper *m, bool enabled) {
    if (m->aircraft_mode == enabled && (!enabled || !m->vehicle_mode)) return;
    m->aircraft_mode = enabled;
    if (enabled) {
        m->vehicle_mode = false;
    }
    m->cruise_active = false;
    m->smooth_steer_lx = 0.0f;
    m->smooth_pitch_ly = 0.0f;
    m->wheel_hold_ms = 0.0f;
}

void psr_mapper_set_smart_mode(PsrMapper *m, bool enabled) {
    if (m->smart_mode == enabled) return;
    m->smart_mode = enabled;
    if (!enabled) {
        m->cruise_active = false;
        m->smooth_steer_lx = 0.0f;
        m->smooth_pitch_ly = 0.0f;
        m->wheel_hold_ms = 0.0f;
        m->swipe_active = false;
    }
}

bool psr_mapper_handle_key(PsrMapper *m, int input_code, bool is_down) {
    if (input_code < 0 || input_code >= PSR_MAX_INPUT_CODE) {
        return false;
    }

    if (input_code == m->cfg.toggle_capture_key) {
        if (is_down && !m->keys_down[input_code]) {
            psr_mapper_set_capture(m, !m->capture_active);
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    if (!m->capture_active) {
        return false;
    }

    if (input_code == m->cfg.toggle_vehicle_key) {
        if (is_down && !m->keys_down[input_code]) {
            m->last_vehicle_was_auto = false;
            m->smart_vehicle_cooldown_ms = 0.0f;
            if (m->aircraft_mode) {
                psr_mapper_set_aircraft_mode(m, false);
            } else {
                psr_mapper_set_vehicle_mode(m, !m->vehicle_mode);
            }
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    if (m->cfg.toggle_aircraft_key >= 0 && input_code == m->cfg.toggle_aircraft_key) {
        if (is_down && !m->keys_down[input_code]) {
            m->last_vehicle_was_auto = false;
            m->smart_vehicle_cooldown_ms = 0.0f;
            psr_mapper_set_aircraft_mode(m, !m->aircraft_mode);
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    if (m->cfg.toggle_smart_key >= 0 && input_code == m->cfg.toggle_smart_key) {
        if (is_down && !m->keys_down[input_code]) {
            psr_mapper_set_smart_mode(m, !m->smart_mode);
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    if (m->cfg.cruise_toggle_key >= 0 && input_code == m->cfg.cruise_toggle_key) {
        if (is_down && !m->keys_down[input_code]) {
            m->cruise_active = !m->cruise_active;
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    if (m->cfg.sens_down_key >= 0 && input_code == m->cfg.sens_down_key) {
        if (is_down && !m->keys_down[input_code]) {
            m->cfg.sensitivity = clampf(roundf((m->cfg.sensitivity - 0.10f) * 100.0f) / 100.0f, 0.40f, 3.00f);
            m->sens_dirty = true;
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    if (m->cfg.sens_up_key >= 0 && input_code == m->cfg.sens_up_key) {
        if (is_down && !m->keys_down[input_code]) {
            m->cfg.sensitivity = clampf(roundf((m->cfg.sensitivity + 0.10f) * 100.0f) / 100.0f, 0.40f, 3.00f);
            m->sens_dirty = true;
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    if (m->cfg.mic_mute_key >= 0 && input_code == m->cfg.mic_mute_key) {
        if (is_down && !m->keys_down[input_code]) {
            m->mic_pressed_edge = true;
        }
        m->keys_down[input_code] = is_down;
        return true;
    }

    /* Any manual gas/brake/move/handbrake press cancels Cruise / Auto-Sprint immediately */
    if (is_down && m->cruise_active &&
        (input_code == m->cfg.move_up_key ||
         input_code == m->cfg.move_down_key ||
         input_code == 49 /* Space */)) {
        m->cruise_active = false;
    }

    /* Smart Mode: pressing 'F' sends Triangle to PS5 AND auto-switches On-Foot <-> Vehicle (or exits Aircraft) */
    if (m->smart_mode &&
        m->cfg.smart_vehicle_key >= 0 &&
        input_code == m->cfg.smart_vehicle_key &&
        is_down && !m->keys_down[input_code]) {
        if (m->smart_vehicle_cooldown_ms <= 0.0f) {
            m->last_vehicle_was_auto = true;
            m->smart_vehicle_cooldown_ms = 900.0f;
            if (m->aircraft_mode) {
                psr_mapper_set_aircraft_mode(m, false);
            } else {
                psr_mapper_set_vehicle_mode(m, !m->vehicle_mode);
            }
        }
    }

    m->keys_down[input_code] = is_down;
    return true;
}

void psr_mapper_add_mouse_delta(PsrMapper *m, float dx, float dy) {
    if (!m->capture_active) return;
    m->pending_dx += dx;
    m->pending_dy += dy;
}

void psr_mapper_add_scroll(PsrMapper *m, float dx, float dy) {
    if (!m->capture_active) return;

    /* While aiming on foot (L2 held), two-finger vertical scroll pulses D-Pad Up/Down for sniper scope zoom */
    if (!m->vehicle_mode && !m->aircraft_mode && m->pad.l2 > 0) {
        if (m->scroll_zoom_cooldown_ms <= 0.0f && fabsf(dy) >= 2.5f) {
            m->scroll_pulse_btn = (dy > 0.0f) ? PSR_BTN_DPAD_UP : PSR_BTN_DPAD_DOWN;
            m->scroll_pulse_ms = 65.0f;
            m->scroll_zoom_cooldown_ms = 120.0f;
        }
        return;
    }

    /* Otherwise in Smart Mode, two-finger flick synthesizes a real DualSense Touchpad Swipe (1920x1080) */
    if (!m->smart_mode || m->swipe_active || m->swipe_cooldown_ms > 0.0f) return;

    float adx = fabsf(dx);
    float ady = fabsf(dy);
    if (adx < 4.5f && ady < 4.5f) return;

    m->swipe_active = true;
    m->swipe_id = (uint8_t)((m->swipe_id + 1) & 0x7F);
    m->swipe_elapsed_ms = 0.0f;

    if (ady >= adx) {
        if (dy > 0.0f) {
            /* Swipe UP */
            m->swipe_start_x = 960.0f; m->swipe_start_y = 880.0f;
            m->swipe_end_x = 960.0f;   m->swipe_end_y = 180.0f;
        } else {
            /* Swipe DOWN */
            m->swipe_start_x = 960.0f; m->swipe_start_y = 180.0f;
            m->swipe_end_x = 960.0f;   m->swipe_end_y = 880.0f;
        }
    } else {
        if (dx > 0.0f) {
            /* Swipe RIGHT */
            m->swipe_start_x = 400.0f;  m->swipe_start_y = 540.0f;
            m->swipe_end_x = 1520.0f;   m->swipe_end_y = 540.0f;
        } else {
            /* Swipe LEFT */
            m->swipe_start_x = 1520.0f; m->swipe_start_y = 540.0f;
            m->swipe_end_x = 400.0f;    m->swipe_end_y = 540.0f;
        }
    }
}

static bool is_key_down(const PsrMapper *m, int code) {
    if (code < 0 || code >= PSR_MAX_INPUT_CODE) return false;
    return m->keys_down[code];
}

static float smooth_ramp_axis(float current, float target, float dt_sec, float turn_rate, float counter_rate, float recenter_rate) {
    float diff = target - current;
    float rate;
    if (fabsf(target) < 0.01f) {
        rate = recenter_rate;
    } else if (target * current < 0.0f) {
        rate = counter_rate;
    } else {
        rate = turn_rate;
    }
    float step = rate * dt_sec;
    if (fabsf(diff) <= step) {
        return target;
    }
    return current + (diff > 0.0f ? step : -step);
}

void psr_mapper_tick(PsrMapper *m, float dt_ms) {
    if (!m->capture_active) {
        memset(&m->pad, 0, sizeof(m->pad));
        return;
    }

    if (dt_ms <= 0.1f) dt_ms = 0.1f;
    if (dt_ms > 100.0f) dt_ms = 100.0f;
    float dt_sec = dt_ms / 1000.0f;

    if (m->smart_vehicle_cooldown_ms > 0.0f) {
        m->smart_vehicle_cooldown_ms -= dt_ms;
        if (m->smart_vehicle_cooldown_ms < 0.0f) m->smart_vehicle_cooldown_ms = 0.0f;
    }
    if (m->swipe_cooldown_ms > 0.0f) {
        m->swipe_cooldown_ms -= dt_ms;
        if (m->swipe_cooldown_ms < 0.0f) m->swipe_cooldown_ms = 0.0f;
    }
    if (m->scroll_zoom_cooldown_ms > 0.0f) {
        m->scroll_zoom_cooldown_ms -= dt_ms;
        if (m->scroll_zoom_cooldown_ms < 0.0f) m->scroll_zoom_cooldown_ms = 0.0f;
    }

    PsrPadState next;
    memset(&next, 0, sizeof(next));

    /* 1. Active mode bindings (buttons + triggers) */
    const PsrBinding *bindings = m->cfg.on_foot;
    int count = m->cfg.on_foot_count;
    if (m->aircraft_mode) {
        bindings = m->cfg.aircraft;
        count = m->cfg.aircraft_count;
    } else if (m->vehicle_mode) {
        bindings = m->cfg.vehicle;
        count = m->cfg.vehicle_count;
    }

    for (int i = 0; i < count; i++) {
        if (!is_key_down(m, bindings[i].input_code)) continue;
        PsrTarget t = bindings[i].target;
        if (t == PSR_TRIGGER_L2) {
            next.l2 = 32767;
        } else if (t == PSR_TRIGGER_R2) {
            next.r2 = 32767;
        } else if (t >= 0 && t < PSR_BTN_COUNT) {
            next.buttons[t] = 1;
        }
    }

    /* Global DualSense Mic Mute button ('[') works in all modes */
    if (m->cfg.mic_mute_key >= 0 && is_key_down(m, m->cfg.mic_mute_key)) {
        next.buttons[PSR_BTN_MIC] = 1;
    }

    /* Rapid-Tap QTE / Bicycle / Swim Assist ('L'): 12.5 Hz Cross pulse */
    bool rapid_held = (m->cfg.rapid_tap_key >= 0) && is_key_down(m, m->cfg.rapid_tap_key);
    if (rapid_held) {
        if (!m->rapid_tap_active) {
            m->rapid_tap_active = true;
            m->rapid_tap_ms = 0.0f;
        }
        if (m->rapid_tap_ms < 40.0f) {
            next.buttons[PSR_BTN_CROSS] = 1;
        }
        m->rapid_tap_ms += dt_ms;
        if (m->rapid_tap_ms >= 80.0f) {
            m->rapid_tap_ms -= 80.0f;
        }
    } else {
        m->rapid_tap_active = false;
        m->rapid_tap_ms = 0.0f;
    }

    /* Two-finger scroll sniper zoom D-Pad pulse */
    if (m->scroll_pulse_ms > 0.0f && m->scroll_pulse_btn >= 0 && m->scroll_pulse_btn < PSR_BTN_COUNT) {
        next.buttons[m->scroll_pulse_btn] = 1;
        m->scroll_pulse_ms -= dt_ms;
        if (m->scroll_pulse_ms <= 0.0f) {
            m->scroll_pulse_ms = 0.0f;
            m->scroll_pulse_btn = -1;
        }
    }

    /* Synthetic DualSense Touchpad Swipe progression (135ms) */
    if (m->swipe_active) {
        const float swipe_dur_ms = 135.0f;
        float t = clampf(m->swipe_elapsed_ms / swipe_dur_ms, 0.0f, 1.0f);
        float tx = m->swipe_start_x + (m->swipe_end_x - m->swipe_start_x) * t;
        float ty = m->swipe_start_y + (m->swipe_end_y - m->swipe_start_y) * t;
        next.touch_active = true;
        next.touch_id = m->swipe_id;
        next.touch_x = (uint16_t)clampf(tx, 0.0f, 1919.0f);
        next.touch_y = (uint16_t)clampf(ty, 0.0f, 1079.0f);

        m->swipe_elapsed_ms += dt_ms;
        if (m->swipe_elapsed_ms >= swipe_dur_ms) {
            m->swipe_active = false;
            m->swipe_elapsed_ms = 0.0f;
            m->swipe_cooldown_ms = 260.0f;
        }
    }

    /* 2. Left stick from WASD / Flight Pitch-Roll + Smart Cruise & Smooth Steering */
    float lx = 0.0f;
    float ly = 0.0f;
    if (is_key_down(m, m->cfg.move_left_key)) lx -= 1.0f;
    if (is_key_down(m, m->cfg.move_right_key)) lx += 1.0f;

    if (m->aircraft_mode) {
        /* Aircraft pitch: Up arrow or LeftShift = Nose Down (-Y), Down arrow or C = Nose Up (+Y) */
        if (is_key_down(m, 126) || is_key_down(m, 56)) ly -= 1.0f;
        if (is_key_down(m, 125) || is_key_down(m, 8))  ly += 1.0f;

        if (m->cruise_active && next.l2 == 0) {
            next.r2 = 27850; /* ~85% smooth flight cruise throttle */
        }
        if (m->smart_mode) {
            m->smooth_steer_lx = smooth_ramp_axis(m->smooth_steer_lx, lx, dt_sec, 9.5f, 24.0f, 18.0f);
            m->smooth_pitch_ly = smooth_ramp_axis(m->smooth_pitch_ly, ly, dt_sec, 9.5f, 24.0f, 18.0f);
            lx = clampf(m->smooth_steer_lx, -1.0f, 1.0f);
            ly = clampf(m->smooth_pitch_ly, -1.0f, 1.0f);
        } else {
            m->smooth_steer_lx = lx;
            m->smooth_pitch_ly = ly;
        }
    } else if (!m->vehicle_mode) {
        if (is_key_down(m, m->cfg.move_up_key)) ly -= 1.0f;
        if (is_key_down(m, m->cfg.move_down_key)) ly += 1.0f;

        if (m->cruise_active) {
            ly = -1.0f;
            next.buttons[PSR_BTN_L3] = 1; /* Auto-Sprint */
        }

        /* Normalize diagonal movement to unit circle */
        float mag = sqrtf(lx * lx + ly * ly);
        if (mag > 1.0f) {
            lx /= mag;
            ly /= mag;
        }
        if (is_key_down(m, m->cfg.walk_mod_key) && !m->cruise_active) {
            float ws = clampf(m->cfg.walk_scale, 0.1f, 1.0f);
            lx *= ws;
            ly *= ws;
        }
        m->smooth_steer_lx = 0.0f;
        m->smooth_pitch_ly = 0.0f;
    } else {
        if (m->cruise_active && next.l2 == 0) {
            next.r2 = 27850; /* ~85% smooth highway cruise throttle */
        }
        if (m->smart_mode) {
            m->smooth_steer_lx = smooth_ramp_axis(m->smooth_steer_lx, lx, dt_sec, 11.5f, 28.0f, 22.0f);
            lx = clampf(m->smooth_steer_lx, -1.0f, 1.0f);
        } else {
            m->smooth_steer_lx = lx;
        }
        m->smooth_pitch_ly = 0.0f;
    }

    next.lx = float_to_axis(lx);
    next.ly = float_to_axis(ly);

    /* 3. Right stick:
     *   Priority 1 = Hotwire Semi-Circle Assist (U)
     *   Priority 2 = 360-deg Full-Circle Assist (I)
     *   Priority 3 = Sticky Virtual R-Stick (Y, or Smart Radial Wheel Tab/Q)
     *   Priority 4 = Trackpad velocity aim with ADS + Precision Sniper (L2+Z) & flick accel */
    float sens = m->cfg.sensitivity > 0.05f ? m->cfg.sensitivity : 1.0f;
    bool hotwire_held = (m->cfg.hotwire_assist_key >= 0) && is_key_down(m, m->cfg.hotwire_assist_key);
    bool circle_held = !hotwire_held && (m->cfg.circle_assist_key >= 0) && is_key_down(m, m->cfg.circle_assist_key);
    bool manual_sticky_held = !hotwire_held && !circle_held &&
                              (m->cfg.rstick_hold_key >= 0) && is_key_down(m, m->cfg.rstick_hold_key);

    /* Smart Auto-Radial Wheel detection:
     * On-Foot: holding Tab (L1) >= 120ms -> Weapon Wheel sticky R-stick
     * Vehicle: holding Q (Square) >= 180ms -> Radio/Weapon Wheel sticky R-stick */
    bool wheel_candidate = false;
    float wheel_threshold_ms = 120.0f;
    if (m->smart_mode && !hotwire_held && !circle_held && !manual_sticky_held && !m->aircraft_mode) {
        if (!m->vehicle_mode && is_key_down(m, 48 /* Tab = L1 */)) {
            wheel_candidate = true;
            wheel_threshold_ms = 120.0f;
        } else if (m->vehicle_mode && is_key_down(m, 12 /* Q = Square */)) {
            wheel_candidate = true;
            wheel_threshold_ms = 180.0f;
        }
    }

    if (wheel_candidate) {
        m->wheel_hold_ms += dt_ms;
    } else {
        m->wheel_hold_ms = 0.0f;
    }
    bool auto_wheel_sticky = wheel_candidate && (m->wheel_hold_ms >= wheel_threshold_ms);
    bool sticky_now = manual_sticky_held || auto_wheel_sticky;

    float rx = 0.0f;
    float ry = 0.0f;

    if (hotwire_held) {
        if (!m->hotwire_active) {
            m->hotwire_active = true;
            m->hotwire_phase = 0.0f;
        }
        m->circle_active = false;
        m->circle_phase = 0.0f;
        m->rstick_sticky_active = false;
        m->rstick_sticky_manual = false;
        m->sticky_rx = 0.0f;
        m->sticky_ry = 0.0f;
        m->pending_dx = 0.0f;
        m->pending_dy = 0.0f;
        m->vel_x = 0.0f;
        m->vel_y = 0.0f;
        m->filt_vx = 0.0f;
        m->filt_vy = 0.0f;
        m->since_motion_ms = 0.0f;
        m->has_active_motion = false;

        /* First 140ms: hold straight down (+Y) so GTA 6 latches the downward (R) prompt.
         * Then smoothly ping-pong across the bottom semi-circle arc (14 deg .. 166 deg). */
        m->hotwire_phase += dt_sec;
        float theta = (float)(M_PI * 0.5);
        if (m->hotwire_phase > 0.14f) {
            float sweep_t = (m->hotwire_phase - 0.14f) * 2.5f;
            theta = (float)(M_PI * 0.5) + (float)(M_PI * 0.42) * sinf(sweep_t);
        }
        rx = cosf(theta) * 0.96f;
        ry = sinf(theta) * 0.96f;
    } else if (circle_held) {
        if (!m->circle_active) {
            m->circle_active = true;
            m->circle_phase = 0.0f;
        }
        m->hotwire_active = false;
        m->hotwire_phase = 0.0f;
        m->rstick_sticky_active = false;
        m->rstick_sticky_manual = false;
        m->sticky_rx = 0.0f;
        m->sticky_ry = 0.0f;
        m->pending_dx = 0.0f;
        m->pending_dy = 0.0f;
        m->vel_x = 0.0f;
        m->vel_y = 0.0f;
        m->filt_vx = 0.0f;
        m->filt_vy = 0.0f;
        m->since_motion_ms = 0.0f;
        m->has_active_motion = false;

        /* Smooth 360-degree clockwise rotation (~3.0 rad/s, ~2.1s per full revolution) */
        m->circle_phase += dt_sec * 3.0f;
        if (m->circle_phase > (float)(2.0 * M_PI)) {
            m->circle_phase -= (float)(2.0 * M_PI);
        }
        rx = cosf(m->circle_phase) * 0.96f;
        ry = sinf(m->circle_phase) * 0.96f;
    } else if (sticky_now) {
        m->hotwire_active = false;
        m->hotwire_phase = 0.0f;
        m->circle_active = false;
        m->circle_phase = 0.0f;

        if (!m->rstick_sticky_active) {
            m->rstick_sticky_active = true;
            m->sticky_rx = 0.0f;
            m->sticky_ry = 0.0f;
            m->vel_x = 0.0f;
            m->vel_y = 0.0f;
            m->filt_vx = 0.0f;
            m->filt_vy = 0.0f;
            m->since_motion_ms = 0.0f;
            m->has_active_motion = false;
        }
        m->rstick_sticky_manual = manual_sticky_held;

        float dx = m->pending_dx;
        float dy = m->cfg.invert_y ? -m->pending_dy : m->pending_dy;
        m->pending_dx = 0.0f;
        m->pending_dy = 0.0f;

        /* Direct position integration: ~115px glide reaches outer rim, stays locked */
        float pos_scale = 0.0065f * sens;
        m->sticky_rx += dx * pos_scale;
        m->sticky_ry += dy * pos_scale;

        float mag = sqrtf(m->sticky_rx * m->sticky_rx + m->sticky_ry * m->sticky_ry);
        if (mag > 1.0f) {
            m->sticky_rx /= mag;
            m->sticky_ry /= mag;
        }
        rx = m->sticky_rx;
        ry = m->sticky_ry;
    } else {
        m->hotwire_active = false;
        m->hotwire_phase = 0.0f;
        m->circle_active = false;
        m->circle_phase = 0.0f;
        if (m->rstick_sticky_active) {
            m->rstick_sticky_active = false;
            m->rstick_sticky_manual = false;
            m->sticky_rx = 0.0f;
            m->sticky_ry = 0.0f;
        }

        float dx = m->pending_dx;
        float dy = m->cfg.invert_y ? -m->pending_dy : m->pending_dy;
        m->pending_dx = 0.0f;
        m->pending_dy = 0.0f;

        bool got_motion = (fabsf(dx) > 0.0001f || fabsf(dy) > 0.0001f);
        float smooth = clampf(m->cfg.smoothing, 0.0f, 0.90f);

        if (got_motion) {
            /* Measure true inter-event interval so 60Hz/90Hz/120Hz trackpad events running inside
             * a 125Hz/250Hz HID timer produce flat, rate-invariant velocity with ZERO sawtooth aliasing. */
            float eff_dt_ms = m->has_active_motion
                ? clampf(m->since_motion_ms + dt_ms, dt_ms, 34.0f)
                : clampf(dt_ms, 4.0f, 20.0f);
            float eff_dt_sec = eff_dt_ms / 1000.0f;
            float inst_vx = dx / eff_dt_sec;
            float inst_vy = dy / eff_dt_sec;

            if (!m->has_active_motion) {
                /* Crisp startup from rest without sluggish ramp-in */
                float start_mix = 0.72f;
                m->vel_x = inst_vx * start_mix;
                m->vel_y = inst_vy * start_mix;
                m->filt_vx = m->vel_x;
                m->filt_vy = m->vel_y;
                m->has_active_motion = true;
            } else {
                float tau_ms = 8.0f + smooth * 36.0f;
                float alpha = 1.0f - expf(-eff_dt_ms / tau_ms);
                float alpha_x = (inst_vx * m->vel_x < 0.0f) ? fmaxf(alpha, 0.72f) : alpha;
                float alpha_y = (inst_vy * m->vel_y < 0.0f) ? fmaxf(alpha, 0.72f) : alpha;
                m->vel_x += (inst_vx - m->vel_x) * alpha_x;
                m->vel_y += (inst_vy - m->vel_y) * alpha_y;
            }
            m->since_motion_ms = 0.0f;
        } else {
            m->since_motion_ms += dt_ms;
            /* Trackpad inter-event coast bridge: macOS trackpad packets can have ~16.7ms spacing
             * between consecutive events. Holding velocity smoothly across the 22ms grace window
             * eliminates 60Hz-vs-250Hz stutter completely, then decays crisply on finger lift. */
            float coast_grace_ms = m->cfg.trackpad_mode ? 22.0f : 10.0f;
            if (m->has_active_motion && m->since_motion_ms <= coast_grace_ms) {
                float micro_bleed = powf(0.5f, dt_ms / 180.0f);
                m->vel_x *= micro_bleed;
                m->vel_y *= micro_bleed;
            } else {
                float raw_hl = m->cfg.decay_half_life_ms > 1.0f ? m->cfg.decay_half_life_ms : 18.0f;
                float stop_hl = m->cfg.trackpad_mode ? fminf(raw_hl * 0.65f, 26.0f) : raw_hl;
                if (stop_hl < 6.0f) stop_hl = 6.0f;
                float decay = powf(0.5f, dt_ms / stop_hl);
                m->vel_x *= decay;
                m->vel_y *= decay;
                if (fabsf(m->vel_x) < 2.0f && fabsf(m->vel_y) < 2.0f) {
                    m->vel_x = 0.0f;
                    m->vel_y = 0.0f;
                    m->has_active_motion = false;
                }
            }
        }

        /* Second-stage critically damped velocity filter (dt-independent):
         * Irons out 1-pixel quantization steps on slow pans while keeping <12ms phase lag. */
        float stage2_tau_ms = 5.0f + smooth * 18.0f;
        float stage2_alpha = 1.0f - expf(-dt_ms / stage2_tau_ms);
        m->filt_vx += (m->vel_x - m->filt_vx) * stage2_alpha;
        m->filt_vy += (m->vel_y - m->filt_vy) * stage2_alpha;
        if (!m->has_active_motion && fabsf(m->filt_vx) < 2.0f && fabsf(m->filt_vy) < 2.0f) {
            m->filt_vx = 0.0f;
            m->filt_vy = 0.0f;
        }

        float max_v = m->cfg.max_velocity_px_per_sec > 100.0f ? m->cfg.max_velocity_px_per_sec : 2600.0f;
        float aim_sens = sens * (m->cfg.trackpad_mode ? 1.45f : 1.0f);
        if (!m->vehicle_mode && !m->aircraft_mode && next.l2 > 0) {
            aim_sens *= clampf(m->cfg.ads_sensitivity_scale, 0.1f, 2.0f);
            /* Precision Sniper Mode: holding L2 (CapsLock) + Z scales aim down further */
            if (is_key_down(m, m->cfg.walk_mod_key)) {
                aim_sens *= clampf(m->cfg.sniper_sensitivity_scale, 0.15f, 1.0f);
            }
        }

        float nx = (m->filt_vx / max_v) * aim_sens;
        float ny = (m->filt_vy / max_v) * aim_sens;
        float speed = sqrtf(nx * nx + ny * ny);

        if (speed > 0.002f) {
            float effective_speed = speed;
            if (m->cfg.trackpad_mode && m->cfg.trackpad_accel > 0.0f) {
                float accel = clampf(m->cfg.trackpad_accel, 0.0f, 4.0f);
                effective_speed = speed * (1.0f + accel * speed);
            }
            float clamped = clampf(effective_speed, 0.0f, 1.0f);
            float exponent = clampf(m->cfg.curve_exponent, 0.25f, 3.0f);
            float shaped = powf(clamped, exponent);
            float dz = clampf(m->cfg.deadzone, 0.0f, 0.45f);
            /* Soft deadzone shoulder prevents harsh 0->dz snap when barely grazing the trackpad,
             * while clearing full GTA deadzone immediately on any intentional pan. */
            float dz_blend = clampf((speed - 0.002f) / 0.018f, 0.0f, 1.0f);
            float dz_smooth = dz_blend * dz_blend * (3.0f - 2.0f * dz_blend);
            float out_mag = dz * dz_smooth + shaped * (1.0f - dz * dz_smooth);
            if (out_mag > 1.0f) out_mag = 1.0f;
            rx = (nx / speed) * out_mag;
            ry = (ny / speed) * out_mag;
        }
    }

    next.rx = float_to_axis(rx);
    next.ry = float_to_axis(ry);
    m->pad = next;
}
