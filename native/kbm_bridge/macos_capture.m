#import "capture_internal.h"

PsrMapper *g_mapper = NULL;
pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
atomic_bool g_running = false;
atomic_bool g_cursor_locked = false;
atomic_bool g_app_active = true;

id g_local_monitor = nil;
id g_resign_observer = nil;
id g_become_observer = nil;

/* Live runtime profile hot-reload tracker */
time_t g_cfg_last_mtime = 0;
int g_cfg_watch_tick = 0;

mach_timebase_info_data_t g_cap_timebase = {0, 0};
uint64_t g_last_haptic_ns = 0;
uint64_t g_last_assist_ui_ns = 0;
uint8_t g_last_led_r = 0;
uint8_t g_last_led_g = 0;
uint8_t g_last_led_b = 0;
bool g_has_led_color = false;
int g_prev_assist_kind = 0;   /* SzAssist last shown */
bool g_prev_aiming_bar = false;

static SzHudState hud_state(bool capture, int mode, bool aiming, bool smart) {
    return (SzHudState){.capture = capture, .mode = mode, .aiming = aiming, .smart = smart};
}

static NSString *mode_label(int mode) {
    return mode == 2 ? @"Uçak" : (mode == 1 ? @"Araç" : @"Yaya");
}

uint64_t cap_now_ns(void) {
    if (g_cap_timebase.denom == 0) {
        mach_timebase_info(&g_cap_timebase);
    }
    return (mach_absolute_time() * g_cap_timebase.numer) / g_cap_timebase.denom;
}

int current_mode_id(bool vehicle_mode, bool aircraft_mode) {
    if (aircraft_mode) return 2;
    if (vehicle_mode) return 1;
    return 0;
}

/* ==================== Live Sensitivity Auto-Save ==================== */

void persist_sensitivity_async(float new_sens) {
    const char *json_env = getenv("SENZA_PROFILE_JSON");
    if (!json_env || json_env[0] == '\0') return;
    NSString *jsonPath = [NSString stringWithUTF8String:json_env];
    double rounded = round((double)new_sens * 100.0) / 100.0;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfFile:jsonPath];
            if (!data) return;
            NSError *err = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&err];
            if (err || ![obj isKindOfClass:[NSMutableDictionary class]]) return;
            NSMutableDictionary *root = (NSMutableDictionary *)obj;
            id mouseObj = root[@"mouse"];
            if (![mouseObj isKindOfClass:[NSMutableDictionary class]]) return;
            ((NSMutableDictionary *)mouseObj)[@"sensitivity"] = @(rounded);
            NSData *outData = [NSJSONSerialization dataWithJSONObject:root
                                                              options:NSJSONWritingPrettyPrinted
                                                                error:&err];
            if (!err && outData) {
                [outData writeToFile:jsonPath atomically:YES];
            }
        }
    });
}

BOOL is_text_input_focused_on_main(void) {
    NSResponder *fr = [NSApp keyWindow].firstResponder;
    if (fr == nil) return NO;
    if ([fr isKindOfClass:[NSText class]] || [fr isKindOfClass:[NSTextField class]]) {
        return YES;
    }
    return NO;
}

void check_profile_hot_reload_on_main(void) {
    const char *cfg_path = getenv("SENZA_PROFILE_CFG");
    if (!cfg_path || cfg_path[0] == '\0' || !g_mapper) return;

    struct stat st;
    if (stat(cfg_path, &st) != 0) return;
    if (g_cfg_last_mtime == 0) {
        g_cfg_last_mtime = st.st_mtime;
        return;
    }
    if (st.st_mtime == g_cfg_last_mtime) return;
    g_cfg_last_mtime = st.st_mtime;

    PsrConfig reloaded;
    if (!psr_config_load_file(cfg_path, &reloaded)) return;

    bool cap_on = false;
    int mode_id = 0;
    bool aiming = false;
    bool smart = true;
    pthread_mutex_lock(&g_lock);
    if (g_mapper) {
        g_mapper->cfg = reloaded;
        cap_on = g_mapper->capture_active;
        mode_id = current_mode_id(g_mapper->vehicle_mode, g_mapper->aircraft_mode);
        aiming = (mode_id == 0 && g_mapper->pad.l2 > 0);
        smart = g_mapper->smart_mode;
    }
    pthread_mutex_unlock(&g_lock);

    fprintf(stderr, "[senza] Hot-reloaded profile from %s (sens=%.2f, deadzone=%.2f)\n",
            cfg_path, reloaded.sensitivity, reloaded.deadzone);
    fflush(stderr);
    hud_prompt_refresh(hud_state(cap_on, mode_id, aiming, smart));
    hud_toast(SZ_TONE_GOOD, @"Profil yeniden yüklendi",
              [NSString stringWithFormat:@"hassasiyet %.2f", reloaded.sensitivity]);
}

void set_mouse_coalescing_safe(BOOL enabled) {
    if ([NSThread isMainThread]) {
        [NSEvent setMouseCoalescingEnabled:enabled];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSEvent setMouseCoalescingEnabled:enabled];
        });
    }
}

void apply_cursor_lock_locked(bool lock) {
    bool currently_locked = atomic_load(&g_cursor_locked);
    if (lock == currently_locked) return;

    if (lock) {
        CGAssociateMouseAndMouseCursorPosition(false);
        CGDisplayHideCursor(CGMainDisplayID());
        set_mouse_coalescing_safe(NO);
        atomic_store(&g_cursor_locked, true);
        fprintf(stderr, "[senza] Capture ON  ('0'=Release, 'G'=Car, 'O'=Aircraft, 'T'=Smart, ';'=Ping, 'H'=HUD)\n");
    } else {
        set_mouse_coalescing_safe(YES);
        CGAssociateMouseAndMouseCursorPosition(true);
        CGDisplayShowCursor(CGMainDisplayID());
        atomic_store(&g_cursor_locked, false);
        fprintf(stderr, "[senza] Capture OFF (cursor released)\n");
    }
    fflush(stderr);
}

bool modifier_flag_is_down(int keycode, NSEventModifierFlags flags) {
    switch (keycode) {
        case 56: /* LeftShift */
        case 60: /* RightShift */
            return (flags & NSEventModifierFlagShift) != 0;
        case 58: /* LeftOption */
        case 61: /* RightOption */
            return (flags & NSEventModifierFlagOption) != 0;
        case 59: /* LeftControl */
        case 62: /* RightControl */
            return (flags & NSEventModifierFlagControl) != 0;
        case 57: /* CapsLock */
            return (flags & NSEventModifierFlagCapsLock) != 0;
        default:
            return false;
    }
}

NSEvent *handle_local_nsevent(NSEvent *event) {
    if (!g_mapper || !event) return event;
    if (!atomic_load(&g_app_active)) return event;

    NSEventType type = [event type];
    NSEventModifierFlags flags = [event modifierFlags];

    /* Always allow Command shortcuts (Cmd+Q, Cmd+Tab, Cmd+H, Cmd+M) */
    if ((flags & NSEventModifierFlagCommand) != 0 &&
        (type == NSEventTypeKeyDown || type == NSEventTypeKeyUp)) {
        return event;
    }

    bool phys_mode_now = (atomic_load(&g_input_source) == 1 && atomic_load(&g_phys_connected));
    bool text_focused = (type == NSEventTypeKeyDown || type == NSEventTypeKeyUp)
        ? is_text_input_focused_on_main()
        : false;

    bool consume = false;
    bool toggle_hud_now = false;
    bool toggle_net_now = false;
    bool toggle_prompt_now = false;
    bool capture_changed = false;
    bool mode_changed = false;
    bool smart_changed = false;
    bool cruise_changed = false;
    bool sens_changed = false;
    bool mic_tapped = false;
    bool now_capture = false;
    int now_mode = 0;
    bool now_aiming = false;
    bool now_smart = false;
    bool now_cruise = false;
    bool mode_was_auto = false;
    float now_sens = 1.35f;

    pthread_mutex_lock(&g_lock);
    bool was_capture = g_mapper->capture_active;
    int was_mode = current_mode_id(g_mapper->vehicle_mode, g_mapper->aircraft_mode);
    bool was_smart = g_mapper->smart_mode;
    bool was_cruise = g_mapper->cruise_active;

    switch (type) {
        case NSEventTypeKeyDown: {
            int keycode = (int)[event keyCode];
            BOOL is_repeat = [event isARepeat];
            bool ctrl_held = (flags & NSEventModifierFlagControl) != 0;
            bool shared_shortcut_ok = g_mapper->capture_active || ctrl_held || (phys_mode_now && !text_focused);
            /* 'H' toggles HUD while captured, in Hybrid DualSense mode, or with Ctrl+H */
            if (keycode == PSR_HUD_KEY_H && shared_shortcut_ok) {
                if (!is_repeat) toggle_hud_now = true;
                consume = true;
                break;
            }
            /* ';' toggles live Ping/AWDL pill while captured, in Hybrid DualSense mode, or with Ctrl+; */
            if (keycode == PSR_NET_KEY_SEMICOLON && shared_shortcut_ok) {
                if (!is_repeat) toggle_net_now = true;
                consume = true;
                break;
            }
            /* '\' toggles bottom-center live PS->Keyboard prompt translator bar */
            if (keycode == PSR_PROMPT_KEY_BACKSLASH && shared_shortcut_ok) {
                if (!is_repeat) toggle_prompt_now = true;
                consume = true;
                break;
            }
            /* '[' triggers PS5 Mic Mute even while using physical DualSense in Hybrid mode */
            if (phys_mode_now && !g_mapper->capture_active && !text_focused &&
                keycode == g_mapper->cfg.mic_mute_key && g_mapper->cfg.mic_mute_key >= 0) {
                if (!is_repeat) {
                    pthread_mutex_lock(&g_phys_lock);
                    g_phys_mic_pulse_ms = 140.0f;
                    pthread_mutex_unlock(&g_phys_lock);
                    mic_tapped = true;
                }
                consume = true;
                break;
            }
            /* Avoid triggering '0' toggle while user is typing in PSN login / search box */
            if (!g_mapper->capture_active && text_focused &&
                keycode == g_mapper->cfg.toggle_capture_key) {
                break;
            }
            consume = psr_mapper_handle_key(g_mapper, keycode, true);
            break;
        }
        case NSEventTypeKeyUp: {
            int keycode = (int)[event keyCode];
            bool shared_up_ok = g_mapper->capture_active || (phys_mode_now && !text_focused);
            if ((keycode == PSR_HUD_KEY_H ||
                 keycode == PSR_NET_KEY_SEMICOLON ||
                 keycode == PSR_PROMPT_KEY_BACKSLASH) && shared_up_ok) {
                consume = true;
                break;
            }
            if (phys_mode_now && !g_mapper->capture_active && !text_focused &&
                keycode == g_mapper->cfg.mic_mute_key && g_mapper->cfg.mic_mute_key >= 0) {
                consume = true;
                break;
            }
            consume = psr_mapper_handle_key(g_mapper, keycode, false);
            break;
        }
        case NSEventTypeFlagsChanged: {
            int keycode = (int)[event keyCode];
            bool is_toggle_key = (keycode == g_mapper->cfg.toggle_capture_key);
            if ((g_mapper->capture_active || is_toggle_key) &&
                (keycode == 56 || keycode == 60 || keycode == 58 || keycode == 61 ||
                 keycode == 59 || keycode == 62 || keycode == 57)) {
                bool is_down = modifier_flag_is_down(keycode, flags);
                consume = psr_mapper_handle_key(g_mapper, keycode, is_down);
            }
            break;
        }
        case NSEventTypeLeftMouseDown:
            consume = psr_mapper_handle_key(g_mapper, PSR_KEY_LMB, true);
            break;
        case NSEventTypeLeftMouseUp:
            consume = psr_mapper_handle_key(g_mapper, PSR_KEY_LMB, false);
            break;
        case NSEventTypeRightMouseDown:
            consume = psr_mapper_handle_key(g_mapper, PSR_KEY_RMB, true);
            break;
        case NSEventTypeRightMouseUp:
            consume = psr_mapper_handle_key(g_mapper, PSR_KEY_RMB, false);
            break;
        case NSEventTypeOtherMouseDown:
        case NSEventTypeOtherMouseUp: {
            NSInteger btn = [event buttonNumber];
            int code = -1;
            if (btn == 2) code = PSR_KEY_MMB;
            else if (btn == 3) code = PSR_KEY_MOUSE4;
            else if (btn == 4) code = PSR_KEY_MOUSE5;
            if (code >= 0) {
                consume = psr_mapper_handle_key(g_mapper, code, type == NSEventTypeOtherMouseDown);
            }
            break;
        }
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged: {
            if (g_mapper->capture_active) {
                CGFloat dx = [event deltaX];
                CGFloat dy = [event deltaY];
                psr_mapper_add_mouse_delta(g_mapper, (float)dx, (float)dy);
                consume = true;
            }
            break;
        }
        case NSEventTypeScrollWheel: {
            if (g_mapper->capture_active) {
                /* Ignore macOS momentum inertia so one 2-finger flick = one clean swipe/zoom */
                if ([event momentumPhase] == NSEventPhaseNone) {
                    CGFloat sdx = [event scrollingDeltaX];
                    CGFloat sdy = [event scrollingDeltaY];
                    /* Normalize to physical finger motion (+dx = right, +dy = up) */
                    BOOL inverted = [event isDirectionInvertedFromDevice];
                    float phys_dx = (float)(inverted ? -sdx : sdx);
                    float phys_dy = (float)(inverted ? -sdy : sdy);
                    psr_mapper_add_scroll(g_mapper, phys_dx, phys_dy);
                }
                consume = true;
            }
            break;
        }
        default:
            break;
    }

    now_capture = g_mapper->capture_active;
    now_mode = current_mode_id(g_mapper->vehicle_mode, g_mapper->aircraft_mode);
    now_aiming = (now_capture && now_mode == 0 && g_mapper->pad.l2 > 0);
    now_smart = g_mapper->smart_mode;
    now_cruise = g_mapper->cruise_active;
    mode_was_auto = g_mapper->last_vehicle_was_auto;
    if (g_mapper->sens_dirty) {
        g_mapper->sens_dirty = false;
        sens_changed = true;
        now_sens = g_mapper->cfg.sensitivity;
    }
    if (g_mapper->mic_pressed_edge) {
        g_mapper->mic_pressed_edge = false;
        mic_tapped = true;
    }

    if (now_capture != was_capture) {
        apply_cursor_lock_locked(now_capture);
        capture_changed = true;
        if (now_capture) {
            atomic_store(&g_input_source, 0);
        } else if (atomic_load(&g_phys_connected)) {
            atomic_store(&g_input_source, 1);
        }
    }
    if (now_mode != was_mode) {
        const char *mode_name = now_mode == 2 ? "AIRCRAFT" : (now_mode == 1 ? "VEHICLE" : "ON-FOOT");
        fprintf(stderr, "[senza] Mode (%s): %s\n", mode_was_auto ? "Smart-F" : "Manual", mode_name);
        fflush(stderr);
        mode_changed = true;
    }
    if (now_smart != was_smart) {
        fprintf(stderr, "[senza] Smart Mode: %s\n", now_smart ? "ON" : "OFF");
        fflush(stderr);
        smart_changed = true;
    }
    if (now_cruise != was_cruise && !capture_changed && !mode_changed && !smart_changed) {
        cruise_changed = true;
    }

    pthread_mutex_unlock(&g_lock);

    /* handle_local_nsevent always runs on main thread */
    SzHudState st = hud_state(now_capture, now_mode, now_aiming, now_smart);
    if (!now_capture && hud_assist_visible()) {
        hud_assist(SZ_ASSIST_NONE, 0, 0);
    }

    if (toggle_net_now) {
        hud_net_set_visible(!hud_net_visible());
    }

    if (toggle_prompt_now) {
        bool on = hud_prompt_toggle(st);
        hud_toast(SZ_TONE_NEUTRAL, on ? @"Alt çubuk açık" : @"Alt çubuk gizlendi", @"{\\}");
    }

    int cur_src = (atomic_load(&g_input_source) == 1 && atomic_load(&g_phys_connected)) ? 1 : 0;

    if (capture_changed || mode_changed || smart_changed) {
        g_prev_aiming_bar = now_aiming;
        hud_prompt_refresh(st);
    }

    if (sens_changed) {
        persist_sensitivity_async(now_sens);
        hud_toast(SZ_TONE_NEUTRAL, [NSString stringWithFormat:@"Hassasiyet %.2f", now_sens], @"kaydedildi");
    } else if (mic_tapped) {
        hud_toast(SZ_TONE_NEUTRAL, @"PS5 mikrofonu", @"sessize alma gönderildi");
    } else if (toggle_hud_now) {
        hud_panel_set_visible(!hud_panel_visible(), st);
    } else if (capture_changed || mode_changed || smart_changed) {
        if (hud_panel_visible()) {
            hud_panel_refresh(st);
        } else if (smart_changed) {
            if (now_smart) {
                hud_toast(SZ_TONE_GOOD, @"Akıllı mod açık", @"{F} araca bin   {V} omuz   {U}{I}{Y}{L} yardımlar");
            } else {
                hud_toast(SZ_TONE_NEUTRAL, @"Akıllı mod kapalı", @"{T} aç");
            }
        } else if (mode_changed) {
            NSString *title = mode_was_auto
                ? [NSString stringWithFormat:@"%@ modu · otomatik", mode_label(now_mode)]
                : [NSString stringWithFormat:@"%@ modu", mode_label(now_mode)];
            NSString *detail = now_mode == 2 ? @"{W}{S} gaz   ok tuşları uçuş   {Q}{E} dümen"
                             : now_mode == 1 ? @"{W}{S} gaz, fren   {Space} el freni   {F} in"
                                             : @"{H} tuşlar   {\\} alt çubuk";
            hud_toast(SZ_TONE_NEUTRAL, title, detail);
        } else if (capture_changed) {
            if (now_capture) {
                hud_toast(SZ_TONE_GOOD, @"Kontrol kilitlendi",
                          [NSString stringWithFormat:@"%@   {0} bırak   {H} tuşlar", mode_label(now_mode)]);
            } else if (cur_src == 1) {
                hud_toast(SZ_TONE_GOOD, @"DualSense aktif", @"{0} trackpad   {;} ping   {H} panel");
            } else {
                hud_toast(SZ_TONE_NEUTRAL, @"İmleç serbest", @"{0} tekrar kilitle");
            }
        }
    } else if (cruise_changed) {
        if (now_cruise) {
            NSString *t = now_mode == 2 ? @"Otomatik uçuş açık" : (now_mode == 1 ? @"Sabit hız açık" : @"Otomatik koşu açık");
            hud_toast(SZ_TONE_GOOD, t, @"{W} {S} {Space} iptal");
        } else {
            hud_toast(SZ_TONE_NEUTRAL, @"Sabit hız kapandı", nil);
        }
    }
    (void)cur_src;

    return consume ? nil : event;
}

void install_cocoa_monitors_on_main(void) {
    @autoreleasepool {
        if (g_local_monitor != nil) return;

        NSEventMask mask =
            NSEventMaskKeyDown |
            NSEventMaskKeyUp |
            NSEventMaskFlagsChanged |
            NSEventMaskMouseMoved |
            NSEventMaskLeftMouseDown |
            NSEventMaskLeftMouseUp |
            NSEventMaskLeftMouseDragged |
            NSEventMaskRightMouseDown |
            NSEventMaskRightMouseUp |
            NSEventMaskRightMouseDragged |
            NSEventMaskOtherMouseDown |
            NSEventMaskOtherMouseUp |
            NSEventMaskOtherMouseDragged |
            NSEventMaskScrollWheel;

        g_local_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                                handler:^NSEvent *(NSEvent *ev) {
            return handle_local_nsevent(ev);
        }];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        g_resign_observer = [nc addObserverForName:NSApplicationDidResignActiveNotification
                                            object:nil
                                             queue:nil
                                        usingBlock:^(NSNotification *note) {
            (void)note;
            atomic_store(&g_app_active, false);
            pthread_mutex_lock(&g_lock);
            if (g_mapper) {
                psr_mapper_set_capture(g_mapper, false);
            }
            apply_cursor_lock_locked(false);
            pthread_mutex_unlock(&g_lock);
            hud_hide_all();
            g_prev_aiming_bar = false;
        }];

        g_become_observer = [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                                            object:nil
                                             queue:nil
                                        usingBlock:^(NSNotification *note) {
            (void)note;
            atomic_store(&g_app_active, true);
        }];

        g_window_close_observer = [nc addObserverForName:NSWindowWillCloseNotification
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification *note) {
            if (g_seen_windows != nil && [note.object isKindOfClass:[NSWindow class]]) {
                [g_seen_windows removeObject:(NSWindow *)note.object];
            }
        }];

        /* Physical DualSense Hybrid Hot-Swap via Apple GameController.framework (zero permissions) */
        if (@available(macOS 11.3, *)) {
            GCController.shouldMonitorBackgroundEvents = YES;
        }
        g_phys_connect_obs = [nc addObserverForName:GCControllerDidConnectNotification
                                             object:nil
                                              queue:[NSOperationQueue mainQueue]
                                         usingBlock:^(NSNotification *note) {
            (void)note;
            refresh_phys_controllers_on_main(true);
        }];
        g_phys_disconnect_obs = [nc addObserverForName:GCControllerDidDisconnectNotification
                                                object:nil
                                                 queue:[NSOperationQueue mainQueue]
                                            usingBlock:^(NSNotification *note) {
            (void)note;
            refresh_phys_controllers_on_main(true);
        }];
        refresh_phys_controllers_on_main(false);

        /* Seed runtime profile mtime for zero-restart Studio hot-reload */
        check_profile_hot_reload_on_main();

        /* Apply Senza icon & bring newly launched app / Remote Play windows to front */
        apply_senza_branding_on_main();
        bring_window_to_front_on_main(nil);
        check_new_windows_and_focus_on_main();
        if (g_window_watch_timer == nil) {
            g_window_watch_timer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue()
            );
            dispatch_source_set_timer(
                g_window_watch_timer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                (uint64_t)(250 * NSEC_PER_MSEC),
                (uint64_t)(50 * NSEC_PER_MSEC)
            );
            dispatch_source_set_event_handler(g_window_watch_timer, ^{
                @autoreleasepool {
                    check_new_windows_and_focus_on_main();
                    if ((++g_cfg_watch_tick & 1) == 0) {
                        check_profile_hot_reload_on_main();
                    }
                }
            });
            dispatch_resume(g_window_watch_timer);
        }

        fprintf(stderr, "[senza] Ready (GTA 6 Smart Pack + Hybrid DualSense)! '0'=Trackpad, '\\'=PromptBar, ';'=Ping, 'H'=HUD.\n");
        fflush(stderr);
    }
}

void cleanup_atexit(void) {
    psr_capture_stop();
}

bool psr_capture_start(PsrMapper *mapper) {
    if (atomic_load(&g_running)) return true;
    g_mapper = mapper;
    atomic_store(&g_running, true);
    atexit(cleanup_atexit);

    if ([NSThread isMainThread]) {
        install_cocoa_monitors_on_main();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            install_cocoa_monitors_on_main();
        });
    }
    return true;
}

void psr_capture_stop(void) {
    atomic_store(&g_net_visible, false);
    if (!atomic_exchange(&g_running, false)) {
        if (atomic_load(&g_cursor_locked)) {
            CGAssociateMouseAndMouseCursorPosition(true);
            CGDisplayShowCursor(CGMainDisplayID());
            atomic_store(&g_cursor_locked, false);
        }
        return;
    }

    pthread_mutex_lock(&g_lock);
    if (g_mapper) {
        psr_mapper_set_capture(g_mapper, false);
    }
    apply_cursor_lock_locked(false);
    pthread_mutex_unlock(&g_lock);

    dispatch_block_t teardown = ^{
        @autoreleasepool {
            if (g_window_watch_timer != nil) {
                dispatch_source_cancel(g_window_watch_timer);
                g_window_watch_timer = nil;
            }
            hud_teardown();
            g_prev_aiming_bar = false;
            if (g_local_monitor != nil) {
                [NSEvent removeMonitor:g_local_monitor];
                g_local_monitor = nil;
            }
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            if (g_resign_observer != nil) {
                [nc removeObserver:g_resign_observer];
                g_resign_observer = nil;
            }
            if (g_become_observer != nil) {
                [nc removeObserver:g_become_observer];
                g_become_observer = nil;
            }
            if (g_window_close_observer != nil) {
                [nc removeObserver:g_window_close_observer];
                g_window_close_observer = nil;
            }
            if (g_phys_connect_obs != nil) {
                [nc removeObserver:g_phys_connect_obs];
                g_phys_connect_obs = nil;
            }
            if (g_phys_disconnect_obs != nil) {
                [nc removeObserver:g_phys_disconnect_obs];
                g_phys_disconnect_obs = nil;
            }
            pthread_mutex_lock(&g_phys_lock);
            attach_phys_controller_locked(nil);
            pthread_mutex_unlock(&g_phys_lock);
            g_seen_windows = nil;
        }
    };

    if ([NSThread isMainThread]) {
        teardown();
    } else {
        dispatch_async(dispatch_get_main_queue(), teardown);
    }
}

void psr_capture_sample_state(float dt_ms, PsrPadState *out_state) {
    /* 1. Check physical DualSense for zero-latency Hybrid Hot-Swap */
    PsrPadState phys_state;
    bool phys_ok = false;
    bool phys_activity = false;
    if (atomic_load(&g_phys_connected)) {
        phys_ok = sample_physical_dualsense(&phys_state, &phys_activity);
    }

    if (phys_ok && phys_activity && atomic_load(&g_input_source) == 0) {
        atomic_store(&g_input_source, 1);
        int mode_id = 0;
        bool smart = true;
        pthread_mutex_lock(&g_lock);
        if (g_mapper) {
            psr_mapper_set_capture(g_mapper, false);
            mode_id = current_mode_id(g_mapper->vehicle_mode, g_mapper->aircraft_mode);
            smart = g_mapper->smart_mode;
        }
        pthread_mutex_unlock(&g_lock);

        dispatch_async(dispatch_get_main_queue(), ^{
            apply_cursor_lock_locked(false);
            g_prev_aiming_bar = false;
            SzHudState st = hud_state(false, mode_id, false, smart);
            hud_prompt_refresh(st);
            hud_assist(SZ_ASSIST_NONE, 0, 0);
            if (hud_panel_visible()) {
                hud_panel_refresh(st);
            } else {
                hud_toast(SZ_TONE_GOOD, @"DualSense'e geçildi", @"{0} trackpad   {;} ping   {H} panel");
            }
        });
    }

    if (phys_ok && atomic_load(&g_input_source) == 1) {
        pthread_mutex_lock(&g_phys_lock);
        if (g_phys_mic_pulse_ms > 0.0f) {
            phys_state.buttons[PSR_BTN_MIC] = 1;
            g_phys_mic_pulse_ms -= dt_ms;
            if (g_phys_mic_pulse_ms < 0.0f) g_phys_mic_pulse_ms = 0.0f;
        }
        pthread_mutex_unlock(&g_phys_lock);

        *out_state = phys_state;
        if (g_prev_assist_kind != 0) {
            g_prev_assist_kind = 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                hud_assist(SZ_ASSIST_NONE, 0, 0);
            });
        }
        return;
    }

    /* 2. Trackpad + Keyboard GTA 6 Smart Pack path */
    int assist_kind = 0; /* 0=none, 1=hotwire, 2=circle, 3=sticky, 4=rapid */
    float srx = 0.0f;
    float sry = 0.0f;
    bool cap_now = false;
    int mode_now = 0;
    bool smart_now = true;
    bool aiming_now = false;

    pthread_mutex_lock(&g_lock);
    if (g_mapper) {
        psr_mapper_tick(g_mapper, dt_ms);
        *out_state = g_mapper->pad;
        cap_now = g_mapper->capture_active;
        mode_now = current_mode_id(g_mapper->vehicle_mode, g_mapper->aircraft_mode);
        smart_now = g_mapper->smart_mode;
        aiming_now = (cap_now && mode_now == 0 && g_mapper->pad.l2 > 0);
        if (g_mapper->hotwire_active) {
            assist_kind = 1;
        } else if (g_mapper->circle_active) {
            assist_kind = 2;
        } else if (g_mapper->rstick_sticky_active && g_mapper->rstick_sticky_manual) {
            assist_kind = 3;
            srx = g_mapper->sticky_rx;
            sry = g_mapper->sticky_ry;
        } else if (g_mapper->rapid_tap_active) {
            assist_kind = 4;
        }
    } else {
        memset(out_state, 0, sizeof(*out_state));
    }
    pthread_mutex_unlock(&g_lock);

    /* Context-reactive bottom PS->Keyboard prompt bar: live-switch YAYA <-> NİŞAN only on transition */
    if (aiming_now != g_prev_aiming_bar) {
        g_prev_aiming_bar = aiming_now;
        dispatch_async(dispatch_get_main_queue(), ^{
            hud_prompt_refresh(hud_state(cap_now, mode_now, aiming_now, smart_now));
        });
    }

    /* Update live top-center assist pill only on state transitions or <=25Hz while holding Y */
    uint64_t now = cap_now_ns();
    bool state_changed = (assist_kind != g_prev_assist_kind);
    bool throttle_ok = (now - g_last_assist_ui_ns) >= 40000000ULL; /* 40ms (~25Hz) */

    if (state_changed || (assist_kind == 3 && throttle_ok)) {
        g_prev_assist_kind = assist_kind;
        g_last_assist_ui_ns = now;

        dispatch_async(dispatch_get_main_queue(), ^{
            hud_assist((SzAssist)assist_kind, srx, sry);
        });
    }
}

void psr_capture_on_dualsense_feedback(const PsrDualSenseFeedback *fb) {
    if (!fb || !atomic_load(&g_running) || !atomic_load(&g_app_active)) return;

    bool phys_mode = (atomic_load(&g_input_source) == 1 && atomic_load(&g_phys_connected));
    if (phys_mode) {
        /* 1. Forward PS5 DualSense rumble motors to physical DualSense via CoreHaptics (~20Hz) */
        if (fb->rumble_left >= 12 || fb->rumble_right >= 12) {
            uint64_t now = cap_now_ns();
            if (now - g_last_phys_rumble_ns >= 50000000ULL) {
                g_last_phys_rumble_ns = now;
                uint8_t rl = fb->rumble_left;
                uint8_t rr = fb->rumble_right;
                dispatch_async(dispatch_get_main_queue(), ^{
                    forward_phys_rumble_on_main(rl, rr);
                });
            }
        }
        /* 2. Forward PS5 Lightbar RGB to both physical DualSense LED and HUD border */
        if (fb->has_lightbar) {
            int diff = abs((int)fb->led_r - (int)g_last_led_r) +
                       abs((int)fb->led_g - (int)g_last_led_g) +
                       abs((int)fb->led_b - (int)g_last_led_b);
            if (!g_has_led_color || diff >= 10) {
                g_last_led_r = fb->led_r;
                g_last_led_g = fb->led_g;
                g_last_led_b = fb->led_b;
                g_has_led_color = true;
                uint8_t r = fb->led_r;
                uint8_t g = fb->led_g;
                uint8_t b = fb->led_b;
                dispatch_async(dispatch_get_main_queue(), ^{
                    forward_phys_lightbar_on_main(r, g, b);
                    hud_lightbar(r, g, b);
                });
            }
        }
        return;
    }

    bool smart_enabled = false;
    bool haptics_enabled = false;
    bool capture_on = false;

    pthread_mutex_lock(&g_lock);
    if (g_mapper) {
        smart_enabled = g_mapper->smart_mode;
        haptics_enabled = g_mapper->cfg.smart_haptics;
        capture_on = g_mapper->capture_active;
    }
    pthread_mutex_unlock(&g_lock);

    if (!smart_enabled || !capture_on) return;

    /* 1. Forward strong DualSense rumble spikes to MacBook Force Touch Trackpad haptics */
    if (haptics_enabled) {
        uint8_t intensity = fb->rumble_left > fb->rumble_right ? fb->rumble_left : fb->rumble_right;
        if (intensity >= 60) {
            uint64_t now = cap_now_ns();
            uint64_t min_gap_ns = (intensity >= 145) ? 75000000ULL : 115000000ULL;
            if (now - g_last_haptic_ns >= min_gap_ns) {
                g_last_haptic_ns = now;
                NSHapticFeedbackPattern pattern = (intensity >= 145)
                    ? NSHapticFeedbackPatternGeneric
                    : NSHapticFeedbackPatternAlignment;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSHapticFeedbackManager defaultPerformer]
                        performFeedbackPattern:pattern
                               performanceTime:NSHapticFeedbackPerformanceTimeNow];
                });
            }
        }
    }

    /* 2. Reflect DualSense Lightbar RGB subtly onto the open HUD border (e.g. Police siren flash) */
    if (fb->has_lightbar) {
        int diff = abs((int)fb->led_r - (int)g_last_led_r) +
                   abs((int)fb->led_g - (int)g_last_led_g) +
                   abs((int)fb->led_b - (int)g_last_led_b);
        if (!g_has_led_color || diff >= 18) {
            g_last_led_r = fb->led_r;
            g_last_led_g = fb->led_g;
            g_last_led_b = fb->led_b;
            g_has_led_color = true;
            uint8_t r = fb->led_r;
            uint8_t g = fb->led_g;
            uint8_t b = fb->led_b;
            dispatch_async(dispatch_get_main_queue(), ^{
                hud_lightbar(r, g, b);
            });
        }
    }
}
