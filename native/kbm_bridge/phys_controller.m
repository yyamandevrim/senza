#import "capture_internal.h"

/* Physical DualSense Hybrid Hot-Swap state (GameController + CoreHaptics, zero permissions) */
pthread_mutex_t g_phys_lock = PTHREAD_MUTEX_INITIALIZER;
GCController *g_phys_controller = nil;
CHHapticEngine *g_phys_haptic_left = nil;
CHHapticEngine *g_phys_haptic_right = nil;
id g_phys_connect_obs = nil;
id g_phys_disconnect_obs = nil;
atomic_bool g_phys_connected = false;
atomic_int g_input_source = 0; /* 0 = Trackpad + Keys, 1 = Physical DualSense */
bool g_phys_touch_was_down = false;
uint8_t g_phys_touch_id = 0;
uint64_t g_last_phys_rumble_ns = 0;
float g_phys_mic_pulse_ms = 0.0f;


/* ==================== Physical DualSense Hybrid Bridge & Profile Hot-Reload ==================== */

int16_t phys_float_to_axis(float v) {
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    if (v >= 0.0f) return (int16_t)lroundf(v * 32767.0f);
    return (int16_t)lroundf(v * 32768.0f);
}

int16_t phys_float_to_trigger(float v) {
    if (v <= 0.0f) return 0;
    if (v >= 1.0f) return 32767;
    return (int16_t)lroundf(v * 32767.0f);
}

void stop_phys_haptics_locked(void) {
    if (g_phys_haptic_left != nil) {
        [g_phys_haptic_left stopWithCompletionHandler:nil];
        g_phys_haptic_left = nil;
    }
    if (g_phys_haptic_right != nil) {
        [g_phys_haptic_right stopWithCompletionHandler:nil];
        g_phys_haptic_right = nil;
    }
}

void attach_phys_controller_locked(GCController *ctrl) {
    if (g_phys_controller == ctrl) return;
    stop_phys_haptics_locked();
    g_phys_controller = ctrl;
    g_phys_touch_was_down = false;
    atomic_store(&g_phys_connected, ctrl != nil);
}

void refresh_phys_controllers_on_main(bool announce_toast) {
    NSArray<GCController *> *all = [GCController controllers];
    GCController *chosen = nil;
    for (GCController *c in all) {
        if ([c.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
            chosen = c;
            break;
        }
    }
    if (chosen == nil) {
        for (GCController *c in all) {
            if (c.extendedGamepad != nil) {
                chosen = c;
                break;
            }
        }
    }

    bool changed = false;
    bool now_connected = (chosen != nil);
    NSString *ctrlName = chosen.vendorName ?: @"DualSense";

    pthread_mutex_lock(&g_phys_lock);
    if (g_phys_controller != chosen) {
        changed = true;
        attach_phys_controller_locked(chosen);
    }
    pthread_mutex_unlock(&g_phys_lock);

    if (!now_connected) {
        atomic_store(&g_input_source, 0);
        if (changed && announce_toast) {
            hud_toast(SZ_TONE_WARN, @"DualSense bağlantısı kesildi", @"{0} trackpad modu");
        }
        return;
    }

    const char *start_hybrid = getenv("SENZA_START_HYBRID");
    bool hybrid_pref = (start_hybrid && strcmp(start_hybrid, "1") == 0);

    bool cap_on = false;
    int mode_id = 0;
    bool smart = true;
    pthread_mutex_lock(&g_lock);
    if (g_mapper) {
        cap_on = g_mapper->capture_active;
        mode_id = current_mode_id(g_mapper->vehicle_mode, g_mapper->aircraft_mode);
        smart = g_mapper->smart_mode;
    }
    pthread_mutex_unlock(&g_lock);

    if (!cap_on && (hybrid_pref || changed)) {
        atomic_store(&g_input_source, 1);
    }

    if (changed) {
        fprintf(stderr, "[senza] Physical controller ready (Hybrid Hot-Swap): %s\n", [ctrlName UTF8String]);
        fflush(stderr);
        if (announce_toast) {
            hud_toast(SZ_TONE_GOOD, [NSString stringWithFormat:@"%@ bağlandı", ctrlName],
                      @"oynamaya başla ya da {0} trackpad");
        }
        hud_panel_refresh((SzHudState){.capture = cap_on, .mode = mode_id, .aiming = false, .smart = smart});
    }
}

bool sample_physical_dualsense(PsrPadState *out, bool *out_activity) {
    memset(out, 0, sizeof(*out));
    if (out_activity) *out_activity = false;

    pthread_mutex_lock(&g_phys_lock);
    GCController *ctrl = g_phys_controller;
    if (ctrl == nil || ctrl.extendedGamepad == nil) {
        pthread_mutex_unlock(&g_phys_lock);
        return false;
    }

    GCExtendedGamepad *gp = ctrl.extendedGamepad;
    float lx = gp.leftThumbstick.xAxis.value;
    float ly = -gp.leftThumbstick.yAxis.value;   /* GC +Y is up; DualSense USB -Y is up */
    float rx = gp.rightThumbstick.xAxis.value;
    float ry = -gp.rightThumbstick.yAxis.value;
    float l2 = gp.leftTrigger.value;
    float r2 = gp.rightTrigger.value;

    out->lx = phys_float_to_axis(lx);
    out->ly = phys_float_to_axis(ly);
    out->rx = phys_float_to_axis(rx);
    out->ry = phys_float_to_axis(ry);
    out->l2 = phys_float_to_trigger(l2);
    out->r2 = phys_float_to_trigger(r2);

    out->buttons[PSR_BTN_CROSS] = gp.buttonA.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_CIRCLE] = gp.buttonB.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_SQUARE] = gp.buttonX.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_TRIANGLE] = gp.buttonY.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_L1] = gp.leftShoulder.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_R1] = gp.rightShoulder.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_L3] = gp.leftThumbstickButton.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_R3] = gp.rightThumbstickButton.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_DPAD_UP] = gp.dpad.up.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_DPAD_DOWN] = gp.dpad.down.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_DPAD_LEFT] = gp.dpad.left.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_DPAD_RIGHT] = gp.dpad.right.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_SHARE] = gp.buttonOptions.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_OPTIONS] = gp.buttonMenu.isPressed ? 1 : 0;
    out->buttons[PSR_BTN_PS] = gp.buttonHome.isPressed ? 1 : 0;

    bool touch_down = false;
    if ([gp isKindOfClass:[GCDualSenseGamepad class]]) {
        GCDualSenseGamepad *ds = (GCDualSenseGamepad *)gp;
        out->buttons[PSR_BTN_TOUCHPAD] = ds.touchpadButton.isPressed ? 1 : 0;
        float tx = ds.touchpadPrimary.xAxis.value;
        float ty = ds.touchpadPrimary.yAxis.value;
        if (fabsf(tx) > 0.0005f || fabsf(ty) > 0.0005f) {
            touch_down = true;
            if (!g_phys_touch_was_down) {
                g_phys_touch_id = (uint8_t)((g_phys_touch_id + 1) & 0x7F);
            }
            float norm_x = (tx + 1.0f) * 0.5f;
            float norm_y = (1.0f - ty) * 0.5f;
            if (norm_x < 0.0f) norm_x = 0.0f;
            if (norm_x > 1.0f) norm_x = 1.0f;
            if (norm_y < 0.0f) norm_y = 0.0f;
            if (norm_y > 1.0f) norm_y = 1.0f;
            out->touch_active = true;
            out->touch_id = g_phys_touch_id;
            out->touch_x = (uint16_t)lroundf(norm_x * 1919.0f);
            out->touch_y = (uint16_t)lroundf(norm_y * 1079.0f);
        }
    }
    g_phys_touch_was_down = touch_down;

    bool active = (fabsf(lx) > 0.22f || fabsf(ly) > 0.22f ||
                   fabsf(rx) > 0.22f || fabsf(ry) > 0.22f ||
                   l2 > 0.15f || r2 > 0.15f || touch_down);
    if (!active) {
        for (int i = 0; i < PSR_BTN_COUNT; i++) {
            if (out->buttons[i]) {
                active = true;
                break;
            }
        }
    }
    if (out_activity) *out_activity = active;
    pthread_mutex_unlock(&g_phys_lock);
    return true;
}

void play_haptic_pulse_on_engine(CHHapticEngine *engine, float intensity, float sharpness) {
    if (engine == nil || intensity <= 0.02f) return;
    NSError *err = nil;
    CHHapticEventParameter *pInt = [[CHHapticEventParameter alloc]
        initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity];
    CHHapticEventParameter *pSharp = [[CHHapticEventParameter alloc]
        initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness];
    CHHapticEvent *ev = [[CHHapticEvent alloc]
        initWithEventType:CHHapticEventTypeHapticContinuous
               parameters:@[pInt, pSharp]
             relativeTime:0.0
                 duration:0.075];
    CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&err];
    if (err || pat == nil) return;
    id<CHHapticPatternPlayer> player = [engine createPlayerWithPattern:pat error:&err];
    if (err || player == nil) return;
    [player startAtTime:CHHapticTimeImmediate error:&err];
}

void forward_phys_rumble_on_main(uint8_t left_val, uint8_t right_val) {
    if (left_val < 12 && right_val < 12) return;
    pthread_mutex_lock(&g_phys_lock);
    GCController *ctrl = g_phys_controller;
    if (ctrl == nil || ctrl.haptics == nil) {
        pthread_mutex_unlock(&g_phys_lock);
        return;
    }
    if (left_val >= 12 && g_phys_haptic_left == nil) {
        g_phys_haptic_left = [ctrl.haptics createEngineWithLocality:GCHapticsLocalityLeftHandle];
        if (g_phys_haptic_left) {
            [g_phys_haptic_left startAndReturnError:nil];
        }
    }
    if (right_val >= 12 && g_phys_haptic_right == nil) {
        g_phys_haptic_right = [ctrl.haptics createEngineWithLocality:GCHapticsLocalityRightHandle];
        if (g_phys_haptic_right) {
            [g_phys_haptic_right startAndReturnError:nil];
        }
    }
    CHHapticEngine *eLeft = g_phys_haptic_left;
    CHHapticEngine *eRight = g_phys_haptic_right;
    pthread_mutex_unlock(&g_phys_lock);

    if (left_val >= 12) {
        play_haptic_pulse_on_engine(eLeft, (float)left_val / 255.0f, 0.25f);
    }
    if (right_val >= 12) {
        play_haptic_pulse_on_engine(eRight, (float)right_val / 255.0f, 0.85f);
    }
}

void forward_phys_lightbar_on_main(uint8_t r, uint8_t g, uint8_t b) {
    pthread_mutex_lock(&g_phys_lock);
    GCController *ctrl = g_phys_controller;
    pthread_mutex_unlock(&g_phys_lock);
    if (ctrl != nil && ctrl.light != nil) {
        ctrl.light.color = [[GCColor alloc] initWithRed:(float)r / 255.0f
                                                  green:(float)g / 255.0f
                                                   blue:(float)b / 255.0f];
    }
}
