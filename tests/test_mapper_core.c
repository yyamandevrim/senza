#include "config_loader.h"
#include "mapper_core.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void test_wasd_diagonal_normalization(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* W (13) + D (2) */
    assert(psr_mapper_handle_key(&m, 13, true));
    assert(psr_mapper_handle_key(&m, 2, true));
    psr_mapper_tick(&m, 8.0f);

    float mag = hypotf((float)m.pad.lx / 32767.0f, (float)m.pad.ly / 32767.0f);
    assert(m.pad.lx > 20000 && m.pad.lx < 25000);
    assert(m.pad.ly < -20000 && m.pad.ly > -25000);
    assert(fabsf(mag - 1.0f) < 0.02f);
}

static void test_mouse_deadzone_and_ads_scaling(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* Small trackpad nudge must clear GTA inner deadzone (>= 0.16 * 32767 = 5242) */
    psr_mapper_add_mouse_delta(&m, 2.0f, 0.0f);
    psr_mapper_tick(&m, 8.0f);
    int16_t hip_rx = m.pad.rx;
    assert(hip_rx >= 5242);

    /* LeftControl / CapsLock (59) holds L2 ADS -> output must be smaller than hipfire */
    psr_mapper_reset_inputs(&m);
    assert(psr_mapper_handle_key(&m, 59, true));
    psr_mapper_add_mouse_delta(&m, 10.0f, 0.0f);
    psr_mapper_tick(&m, 8.0f);
    int16_t ads_rx = m.pad.rx;
    assert(m.pad.l2 == 32767);

    psr_mapper_reset_inputs(&m);
    psr_mapper_add_mouse_delta(&m, 10.0f, 0.0f);
    psr_mapper_tick(&m, 8.0f);
    int16_t hip_rx_10 = m.pad.rx;
    assert(ads_rx > 5242 && ads_rx < hip_rx_10);

    /* Decay back to zero when finger lifts off trackpad */
    for (int i = 0; i < 80; i++) {
        psr_mapper_tick(&m, 16.0f);
    }
    assert(m.pad.rx == 0 && m.pad.ry == 0);
}

static void test_vehicle_mode_and_release_reset(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);

    /* '0' (29) toggles capture ON (Karabiner-safe, no F-keys/RightOption/Cmd/Fn) */
    assert(psr_mapper_handle_key(&m, 29, true));
    assert(psr_mapper_handle_key(&m, 29, false));
    assert(m.capture_active == true);

    /* G (5) toggles Vehicle Mode ON */
    assert(psr_mapper_handle_key(&m, 5, true));
    assert(psr_mapper_handle_key(&m, 5, false));
    assert(m.vehicle_mode == true);

    /* In Vehicle Mode (Smart Mode ON): A ramps smoothly and hits full lock within ~100ms.
     * Official GTA 6 Vehicle controls: Space=CROSS (Handbrake/Bike Speed Up), LMB/Q=R1 (Shoot),
     * C=CIRCLE (Headlights/Hold Duck), R=SQUARE (Melee), Tab=L1 (Loadout Wheel). */
    psr_mapper_handle_key(&m, 13, true); /* W -> R2 */
    psr_mapper_handle_key(&m, 0, true);  /* A -> smooth steer */
    psr_mapper_handle_key(&m, 49, true); /* Space -> CROSS (Handbrake) */
    psr_mapper_handle_key(&m, PSR_KEY_LMB, true); /* LMB -> R1 (Shoot) */
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.r2 == 32767);
    assert(m.pad.ly == 0);
    assert(m.pad.lx < 0 && m.pad.lx > -10000); /* Gentle initial ramp on short tap */
    assert(m.pad.buttons[PSR_BTN_CROSS] == 1);
    assert(m.pad.buttons[PSR_BTN_R1] == 1);

    for (int i = 0; i < 15; i++) {
        psr_mapper_tick(&m, 8.0f);
    }
    assert(m.pad.lx < -32000); /* Full lock reached smoothly */

    /* Holding Tab (48 = L1) >= 135ms in Vehicle Mode also activates Sticky Loadout Wheel */
    psr_mapper_handle_key(&m, 48, true);
    for (int i = 0; i < 12; i++) {
        psr_mapper_tick(&m, 16.0f);
    }
    assert(m.pad.buttons[PSR_BTN_L1] == 1);
    assert(m.rstick_sticky_active == true);
    psr_mapper_handle_key(&m, 48, false);

    /* Releasing capture zeroes all outputs (no stuck keys/triggers) */
    psr_mapper_set_capture(&m, false);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.r2 == 0 && m.pad.lx == 0 &&
           m.pad.buttons[PSR_BTN_CROSS] == 0 && m.pad.buttons[PSR_BTN_R1] == 0);
}

static void test_smart_hotwire_and_sticky_rstick(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* Hold 'U' (32) -> bottom semi-circle hotwire sweep */
    assert(psr_mapper_handle_key(&m, 32, true));
    psr_mapper_tick(&m, 16.0f);
    assert(m.hotwire_active == true);
    assert(m.pad.ry > 30000); /* Initial downward latch (+Y) */

    int16_t min_rx = 32767, max_rx = -32768;
    for (int i = 0; i < 150; i++) {
        psr_mapper_tick(&m, 16.0f);
        assert(m.pad.ry > 5000); /* Always stays inside bottom semi-circle */
        if (m.pad.rx < min_rx) min_rx = m.pad.rx;
        if (m.pad.rx > max_rx) max_rx = m.pad.rx;
    }
    assert(min_rx < -20000 && max_rx > 20000); /* Sweeps left <-> right cleanly */
    psr_mapper_handle_key(&m, 32, false);
    psr_mapper_tick(&m, 16.0f);
    assert(m.hotwire_active == false);
    assert(m.pad.rx == 0 && m.pad.ry == 0);

    /* Hold 'Y' (16) -> sticky virtual right-stick (does NOT decay when finger stops) */
    assert(psr_mapper_handle_key(&m, 16, true));
    psr_mapper_add_mouse_delta(&m, 80.0f, 80.0f);
    psr_mapper_tick(&m, 8.0f);
    int16_t held_rx = m.pad.rx;
    int16_t held_ry = m.pad.ry;
    assert(held_rx > 15000 && held_ry > 15000);

    /* 50 idle ticks while 'Y' is still held -> position must stay locked */
    for (int i = 0; i < 50; i++) {
        psr_mapper_tick(&m, 16.0f);
    }
    assert(m.pad.rx == held_rx && m.pad.ry == held_ry);

    /* Releasing 'Y' resets sticky R-stick back to neutral */
    psr_mapper_handle_key(&m, 16, false);
    psr_mapper_tick(&m, 8.0f);
    assert(m.rstick_sticky_active == false);
    assert(m.pad.rx == 0 && m.pad.ry == 0);
}

static void test_smart_radial_wheel_auto_vehicle_and_cruise(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* Holding Tab (48 = L1) >= 135ms activates Sticky Weapon Wheel */
    psr_mapper_handle_key(&m, 48, true);
    for (int i = 0; i < 12; i++) {
        psr_mapper_tick(&m, 16.0f);
    }
    assert(m.pad.buttons[PSR_BTN_L1] == 1);
    assert(m.rstick_sticky_active == true);
    psr_mapper_add_mouse_delta(&m, -100.0f, -100.0f);
    psr_mapper_tick(&m, 8.0f);
    int16_t slot_x = m.pad.rx;
    int16_t slot_y = m.pad.ry;
    assert(slot_x < -18000 && slot_y < -18000);
    psr_mapper_tick(&m, 50.0f); /* Stays locked on selected weapon slot */
    assert(m.pad.rx == slot_x && m.pad.ry == slot_y);
    psr_mapper_handle_key(&m, 48, false);
    psr_mapper_tick(&m, 8.0f);
    assert(m.rstick_sticky_active == false);

    /* Smart 1-Tap Switch Shoulder: tap 'V' (9) while aiming L2 (59) -> holds DPAD_LEFT 480ms, suppresses SQUARE */
    psr_mapper_handle_key(&m, 59, true);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.l2 == 32767);
    psr_mapper_handle_key(&m, 9, true);
    psr_mapper_tick(&m, 16.0f);
    assert(m.pad.buttons[PSR_BTN_DPAD_LEFT] == 1);
    assert(m.pad.buttons[PSR_BTN_SQUARE] == 0);
    psr_mapper_handle_key(&m, 9, false);
    psr_mapper_tick(&m, 200.0f);
    assert(m.pad.buttons[PSR_BTN_DPAD_LEFT] == 1); /* Still held cleanly across 480ms */
    for (int i = 0; i < 20; i++) {
        psr_mapper_tick(&m, 20.0f);
    }
    assert(m.pad.buttons[PSR_BTN_DPAD_LEFT] == 0);
    psr_mapper_handle_key(&m, 59, false);

    /* 'E' (14) sends Triangle WITHOUT flipping vehicle_mode */
    psr_mapper_handle_key(&m, 14, true);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.buttons[PSR_BTN_TRIANGLE] == 1);
    assert(m.vehicle_mode == false);
    psr_mapper_handle_key(&m, 14, false);

    /* 'F' (3) in Smart Mode sends Triangle AND auto-switches to Vehicle Mode */
    psr_mapper_handle_key(&m, 3, true);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.buttons[PSR_BTN_TRIANGLE] == 1);
    assert(m.vehicle_mode == true);
    assert(m.last_vehicle_was_auto == true);
    psr_mapper_handle_key(&m, 3, false);

    /* Cruise toggle ']' (30) in Vehicle Mode holds ~85% R2 throttle, cancels on S (1) */
    psr_mapper_handle_key(&m, 30, true);
    psr_mapper_handle_key(&m, 30, false);
    psr_mapper_tick(&m, 8.0f);
    assert(m.cruise_active == true);
    assert(m.pad.r2 > 25000 && m.pad.r2 < 30000);
    psr_mapper_handle_key(&m, 1, true); /* S cancels cruise */
    psr_mapper_tick(&m, 8.0f);
    assert(m.cruise_active == false);
    assert(m.pad.l2 == 32767 && m.pad.r2 == 0);
    psr_mapper_handle_key(&m, 1, false);

    /* Toggle Smart Mode OFF with 'T' (17) -> raw instant steering */
    psr_mapper_handle_key(&m, 17, true);
    psr_mapper_handle_key(&m, 17, false);
    assert(m.smart_mode == false);
    psr_mapper_handle_key(&m, 0, true); /* A */
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.lx < -32000); /* Instant full lock when Smart Mode is OFF */
}

static void test_circle_assist_and_rapid_tap(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* Hold 'I' (34) -> 360-degree clockwise R-stick rotation covering all 4 quadrants */
    assert(psr_mapper_handle_key(&m, 34, true));
    bool seen_q1 = false, seen_q2 = false, seen_q3 = false, seen_q4 = false;
    for (int i = 0; i < 160; i++) {
        psr_mapper_tick(&m, 16.0f);
        assert(m.circle_active == true);
        if (m.pad.rx > 12000 && m.pad.ry > 12000) seen_q1 = true;
        if (m.pad.rx < -12000 && m.pad.ry > 12000) seen_q2 = true;
        if (m.pad.rx < -12000 && m.pad.ry < -12000) seen_q3 = true;
        if (m.pad.rx > 12000 && m.pad.ry < -12000) seen_q4 = true;
    }
    assert(seen_q1 && seen_q2 && seen_q3 && seen_q4);
    psr_mapper_handle_key(&m, 34, false);
    psr_mapper_tick(&m, 16.0f);
    assert(m.circle_active == false);
    assert(m.pad.rx == 0 && m.pad.ry == 0);

    /* Hold 'L' (37) -> 12.5Hz rhythmic Cross pulsing (ON 40ms / OFF 40ms) */
    assert(psr_mapper_handle_key(&m, 37, true));
    int rising_edges = 0;
    uint8_t prev_cross = 0;
    for (int i = 0; i < 50; i++) {
        psr_mapper_tick(&m, 10.0f);
        assert(m.rapid_tap_active == true);
        if (m.pad.buttons[PSR_BTN_CROSS] && !prev_cross) {
            rising_edges++;
        }
        prev_cross = m.pad.buttons[PSR_BTN_CROSS];
    }
    assert(rising_edges >= 5 && rising_edges <= 7);
    psr_mapper_handle_key(&m, 37, false);
    psr_mapper_tick(&m, 10.0f);
    assert(m.rapid_tap_active == false);
    assert(m.pad.buttons[PSR_BTN_CROSS] == 0);
}

static void test_aircraft_mode_controls(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* 'O' (31) toggles Aircraft Mode ON (mutually exclusive with vehicle_mode) */
    assert(psr_mapper_handle_key(&m, 31, true));
    assert(psr_mapper_handle_key(&m, 31, false));
    assert(m.aircraft_mode == true && m.vehicle_mode == false);

    /* Official GTA 6 Aircraft controls:
     * W (13) = R2 throttle, Q (12) = SQUARE (Yaw Left), E (14) = CIRCLE (Yaw Right),
     * UpArrow (126) = pitch forward (-LY), LeftArrow (123) = smooth roll left (-LX). */
    psr_mapper_handle_key(&m, 13, true);
    psr_mapper_handle_key(&m, 12, true);
    psr_mapper_handle_key(&m, 126, true);
    psr_mapper_handle_key(&m, 123, true);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.r2 == 32767);
    assert(m.pad.buttons[PSR_BTN_SQUARE] == 1);
    assert(m.pad.lx < 0 && m.pad.lx > -12000);
    assert(m.pad.ly < 0 && m.pad.ly > -12000);

    for (int i = 0; i < 30; i++) {
        psr_mapper_tick(&m, 8.0f);
    }
    assert(m.pad.lx < -32000);
    assert(m.pad.ly < -32000);
    psr_mapper_handle_key(&m, 12, false);
    psr_mapper_handle_key(&m, 126, false);
    psr_mapper_handle_key(&m, 123, false);

    /* E (14) = CIRCLE (Yaw Right), Space (49) = R1 (Shoot), R (15) = L3 (Undercarriage) */
    psr_mapper_handle_key(&m, 14, true);
    psr_mapper_handle_key(&m, 49, true);
    psr_mapper_handle_key(&m, 15, true);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.buttons[PSR_BTN_CIRCLE] == 1);
    assert(m.pad.buttons[PSR_BTN_R1] == 1);
    assert(m.pad.buttons[PSR_BTN_L3] == 1);
    psr_mapper_handle_key(&m, 14, false);
    psr_mapper_handle_key(&m, 49, false);
    psr_mapper_handle_key(&m, 15, false);

    /* 'F' (3) in Aircraft Mode sends Triangle AND auto-exits to On-Foot */
    psr_mapper_handle_key(&m, 3, true);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.buttons[PSR_BTN_TRIANGLE] == 1);
    assert(m.aircraft_mode == false && m.vehicle_mode == false);
    psr_mapper_handle_key(&m, 3, false);
}

static void test_live_sensitivity_sniper_and_mic_mute(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    float orig = m.cfg.sensitivity;
    /* '=' (24) increases sensitivity by 0.10 and flags sens_dirty */
    assert(psr_mapper_handle_key(&m, 24, true));
    assert(psr_mapper_handle_key(&m, 24, false));
    assert(fabsf(m.cfg.sensitivity - (orig + 0.10f)) < 0.001f);
    assert(m.sens_dirty == true);

    /* '-' (27) decreases sensitivity back to original */
    m.sens_dirty = false;
    assert(psr_mapper_handle_key(&m, 27, true));
    assert(psr_mapper_handle_key(&m, 27, false));
    assert(fabsf(m.cfg.sensitivity - orig) < 0.001f);
    assert(m.sens_dirty == true);

    /* Precision Sniper: holding L2 (59) + Z (6) must scale lower than L2 alone */
    psr_mapper_reset_inputs(&m);
    psr_mapper_handle_key(&m, 59, true);
    psr_mapper_add_mouse_delta(&m, 24.0f, 0.0f);
    psr_mapper_tick(&m, 8.0f);
    int16_t ads_rx = m.pad.rx;

    psr_mapper_reset_inputs(&m);
    psr_mapper_handle_key(&m, 59, true);
    psr_mapper_handle_key(&m, 6, true); /* Z = Sniper precision */
    psr_mapper_add_mouse_delta(&m, 24.0f, 0.0f);
    psr_mapper_tick(&m, 8.0f);
    int16_t sniper_rx = m.pad.rx;
    assert(sniper_rx > 5242 && sniper_rx < ads_rx);

    /* '[' (33) triggers PS5 Mic Mute button across all modes + mic_pressed_edge */
    psr_mapper_reset_inputs(&m);
    assert(psr_mapper_handle_key(&m, 33, true));
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.buttons[PSR_BTN_MIC] == 1);
    assert(m.mic_pressed_edge == true);
    psr_mapper_handle_key(&m, 33, false);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.buttons[PSR_BTN_MIC] == 0);
}

static void test_two_finger_scroll_touchpad_swipe_and_sniper_zoom(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* Normal gameplay: 2-finger swipe right (+dx) -> DualSense capacitive touchpad swipe */
    psr_mapper_add_scroll(&m, 30.0f, 0.0f);
    psr_mapper_tick(&m, 10.0f);
    assert(m.pad.touch_active == true);
    uint16_t x_start = m.pad.touch_x;
    psr_mapper_tick(&m, 80.0f);
    assert(m.pad.touch_active == true);
    uint16_t x_mid = m.pad.touch_x;
    assert(x_mid > x_start);

    /* Completes after 135ms and lifts finger on the following tick */
    psr_mapper_tick(&m, 80.0f);
    assert(m.swipe_active == false);
    psr_mapper_tick(&m, 16.0f);
    assert(m.pad.touch_active == false);

    /* Cooldown elapsed -> while aiming L2 (59), vertical scroll pulses DPAD_UP (zoom in) */
    for (int i = 0; i < 20; i++) {
        psr_mapper_tick(&m, 20.0f);
    }
    psr_mapper_handle_key(&m, 59, true);
    psr_mapper_tick(&m, 8.0f);
    assert(m.pad.l2 == 32767);

    psr_mapper_add_scroll(&m, 0.0f, 25.0f);
    psr_mapper_tick(&m, 16.0f);
    assert(m.pad.touch_active == false);
    assert(m.pad.buttons[PSR_BTN_DPAD_UP] == 1);

    /* Pulse ends cleanly after 140ms and releases on the following tick */
    for (int i = 0; i < 4; i++) {
        psr_mapper_tick(&m, 40.0f);
    }
    assert(m.scroll_pulse_ms == 0.0f);
    psr_mapper_tick(&m, 16.0f);
    assert(m.pad.buttons[PSR_BTN_DPAD_UP] == 0);
}

static void test_trackpad_smoothness_no_sawtooth(void) {
    PsrMapper m;
    psr_mapper_init(&m, NULL);
    psr_mapper_set_capture(&m, true);

    /* Simulate steady MacBook Trackpad pan: 60Hz NSEvents (dx=8px every 16ms)
     * sampled inside a 250Hz HID timer (dt=4ms). Steady-state ripple must stay < 4%. */
    int16_t min_rx = 32767;
    int16_t max_rx = -32768;
    for (int tick = 0; tick < 100; tick++) {
        if ((tick % 4) == 0) {
            psr_mapper_add_mouse_delta(&m, 8.0f, 0.0f);
        }
        psr_mapper_tick(&m, 4.0f);
        if (tick >= 40) {
            if (m.pad.rx < min_rx) min_rx = m.pad.rx;
            if (m.pad.rx > max_rx) max_rx = m.pad.rx;
        }
    }
    assert(min_rx > 10000);
    float ripple_ratio = (float)(max_rx - min_rx) / (float)max_rx;
    assert(ripple_ratio < 0.04f);

    /* Finger lifts -> camera stops cleanly to 0 within 220ms */
    for (int tick = 0; tick < 55; tick++) {
        psr_mapper_tick(&m, 4.0f);
    }
    assert(m.pad.rx == 0 && m.pad.ry == 0);
}

int main(void) {
    test_wasd_diagonal_normalization();
    test_mouse_deadzone_and_ads_scaling();
    test_vehicle_mode_and_release_reset();
    test_smart_hotwire_and_sticky_rstick();
    test_smart_radial_wheel_auto_vehicle_and_cruise();
    test_circle_assist_and_rapid_tap();
    test_aircraft_mode_controls();
    test_live_sensitivity_sniper_and_mic_mute();
    test_two_finger_scroll_touchpad_swipe_and_sniper_zoom();
    test_trackpad_smoothness_no_sawtooth();
    printf("All mapper_core C tests passed!\n");
    return 0;
}
