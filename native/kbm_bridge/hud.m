#import "capture_internal.h"

/* Non-activating, click-through, fullscreen-safe overlay panel */
@implementation PsrHudPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

/* Compact top-right Controls HUD (only active mode, low visual footprint) */
PsrHudPanel *g_hud_panel = nil;
NSView *g_hud_bg_view = nil;
BOOL g_hud_visible = NO;
int g_hud_last_mode = 0; /* 0=on-foot, 1=vehicle, 2=aircraft */
BOOL g_hud_last_capture = NO;
BOOL g_hud_last_smart = YES;
int g_hud_last_source = 0; /* 0=Trackpad+Keys, 1=Physical DualSense */

/* Micro top-center status pill (auto-fades in 1.6s on toggles/adjustments) */
PsrHudPanel *g_toast_panel = nil;
NSTextField *g_toast_label = nil;
uint64_t g_toast_gen = 0;

/* Live top-center minigame assist pill (visible ONLY while holding U, I, Y, or L) */
PsrHudPanel *g_assist_panel = nil;
NSTextField *g_assist_label = nil;
BOOL g_assist_visible = NO;
int g_prev_assist_kind = 0; /* 0=none, 1=hotwire, 2=circle, 3=sticky, 4=rapid */

/* Ultra-slim top-left live Network / Ping / AWDL telemetry pill (toggled with ';') */
PsrHudPanel *g_net_panel = nil;
NSTextField *g_net_label = nil;
atomic_bool g_net_visible = false;
atomic_bool g_net_thread_active = false;
pthread_t g_net_thread;

/* Slim bottom-center live PS->Keyboard Prompt Translator Bar (toggled with '\', ON by default while captured) */
PsrHudPanel *g_prompt_panel = nil;
NSTextField *g_prompt_label = nil;
BOOL g_prompt_enabled = YES;
BOOL g_prompt_visible = NO;
bool g_prev_aiming_bar = false;

NSTextField *make_label(NSString *text, NSFont *font, NSColor *color, NSTextAlignment align) {
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
    tf.stringValue = text;
    tf.font = font;
    tf.textColor = color;
    tf.alignment = align;
    tf.bordered = NO;
    tf.bezeled = NO;
    tf.drawsBackground = NO;
    tf.editable = NO;
    tf.selectable = NO;
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    return tf;
}

PsrHudPanel *create_overlay_panel(NSRect rect) {
    PsrHudPanel *panel = [[PsrHudPanel alloc]
        initWithContentRect:rect
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.hidesOnDeactivate = NO;
    panel.level = NSScreenSaverWindowLevel;
    panel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle;
    return panel;
}

NSScreen *active_screen_on_main(void) {
    return [NSApp keyWindow].screen ?: [NSScreen mainScreen];
}

void update_net_pill_on_main(NSString *text, NSColor *color) {
    if (!atomic_load(&g_net_visible) || g_net_panel == nil || g_net_label == nil) return;
    g_net_label.stringValue = text;
    g_net_label.textColor = color;
}

void set_net_visible_on_main(BOOL visible) {
    if (visible) {
        if (g_net_panel == nil) {
            g_net_panel = create_overlay_panel(NSMakeRect(0, 0, 265, 24));
            NSView *bg = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 265, 24)];
            bg.wantsLayer = YES;
            bg.layer.cornerRadius = 12.0;
            bg.layer.backgroundColor = [NSColor colorWithRed:0.04 green:0.05 blue:0.08 alpha:0.66].CGColor;
            bg.layer.borderWidth = 0.75;
            bg.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.14].CGColor;

            g_net_label = make_label(
                @"● Ağ ölçülüyor...",
                [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightSemibold],
                [NSColor colorWithWhite:0.86 alpha:1.0],
                NSTextAlignmentCenter
            );
            g_net_label.frame = NSMakeRect(8, 4, 249, 15);
            [bg addSubview:g_net_label];
            g_net_panel.contentView = bg;
        }

        NSScreen *screen = active_screen_on_main();
        if (screen) {
            NSRect sf = screen.visibleFrame;
            NSRect wf = g_net_panel.frame;
            CGFloat x = sf.origin.x + 16.0;
            CGFloat y = sf.origin.y + sf.size.height - wf.size.height - 12.0;
            [g_net_panel setFrameOrigin:NSMakePoint(x, y)];
        }

        atomic_store(&g_net_visible, true);
        [g_net_panel orderFrontRegardless];

        if (!atomic_exchange(&g_net_thread_active, true)) {
            pthread_create(&g_net_thread, NULL, net_telemetry_thread, NULL);
            pthread_detach(g_net_thread);
        }
        fprintf(stderr, "[senza] Live Ping/AWDL pill ON  (top-left, press ';' to hide)\n");
        fflush(stderr);
    } else {
        atomic_store(&g_net_visible, false);
        if (g_net_panel != nil) {
            [g_net_panel orderOut:nil];
        }
    }
}

/* ==================== Toasts & Assist Micro-Pill ==================== */

void show_toast_on_main(NSString *text, NSColor *accent) {
    if (g_hud_visible || g_assist_visible) return;
    if (g_toast_panel == nil) {
        g_toast_panel = create_overlay_panel(NSMakeRect(0, 0, 410, 26));
        NSView *bg = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 410, 26)];
        bg.wantsLayer = YES;
        bg.layer.cornerRadius = 13.0;
        bg.layer.backgroundColor = [NSColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:0.68].CGColor;
        bg.layer.borderWidth = 0.75;
        bg.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.16].CGColor;

        g_toast_label = make_label(
            @"",
            [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightSemibold],
            [NSColor whiteColor],
            NSTextAlignmentCenter
        );
        g_toast_label.frame = NSMakeRect(10, 5, 390, 16);
        [bg addSubview:g_toast_label];
        g_toast_panel.contentView = bg;
    }

    g_toast_label.stringValue = text;
    g_toast_label.textColor = accent;

    NSScreen *screen = active_screen_on_main();
    if (screen) {
        NSRect sf = screen.visibleFrame;
        NSRect wf = g_toast_panel.frame;
        CGFloat x = sf.origin.x + (sf.size.width - wf.size.width) * 0.5;
        CGFloat y = sf.origin.y + sf.size.height - wf.size.height - 12.0;
        [g_toast_panel setFrameOrigin:NSMakePoint(x, y)];
    }

    g_toast_panel.alphaValue = 1.0;
    [g_toast_panel orderFrontRegardless];

    uint64_t my_gen = ++g_toast_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_toast_gen != my_gen || g_toast_panel == nil) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.25;
            g_toast_panel.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (g_toast_gen == my_gen && g_toast_panel != nil) {
                [g_toast_panel orderOut:nil];
            }
        }];
    });
}

NSString *stick_direction_glyph(float rx, float ry) {
    float mag = hypotf(rx, ry);
    if (mag < 0.12f) return @"●";
    float angle = atan2f(ry, rx); /* 0=right, +pi/2=down, -pi/2=up */
    if (angle >= -0.3927f && angle < 0.3927f) return @"→";
    if (angle >= 0.3927f && angle < 1.1781f) return @"↘";
    if (angle >= 1.1781f && angle < 1.9635f) return @"↓";
    if (angle >= 1.9635f && angle < 2.7489f) return @"↙";
    if (angle >= 2.7489f || angle < -2.7489f) return @"←";
    if (angle >= -2.7489f && angle < -1.9635f) return @"↖";
    if (angle >= -1.9635f && angle < -1.1781f) return @"↑";
    return @"↗";
}

void update_assist_pill_on_main(BOOL visible, NSString *text, NSColor *accent) {
    if (!visible) {
        if (g_assist_panel != nil && g_assist_visible) {
            [g_assist_panel orderOut:nil];
            g_assist_visible = NO;
        }
        return;
    }

    if (g_toast_panel != nil) {
        ++g_toast_gen;
        [g_toast_panel orderOut:nil];
    }

    if (g_assist_panel == nil) {
        g_assist_panel = create_overlay_panel(NSMakeRect(0, 0, 325, 26));
        NSView *bg = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 325, 26)];
        bg.wantsLayer = YES;
        bg.layer.cornerRadius = 13.0;
        bg.layer.backgroundColor = [NSColor colorWithRed:0.06 green:0.07 blue:0.11 alpha:0.78].CGColor;
        bg.layer.borderWidth = 1.0;
        bg.layer.borderColor = [NSColor colorWithRed:1.0 green:0.80 blue:0.35 alpha:0.55].CGColor;

        g_assist_label = make_label(
            @"",
            [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightBold],
            [NSColor whiteColor],
            NSTextAlignmentCenter
        );
        g_assist_label.frame = NSMakeRect(10, 5, 305, 16);
        [bg addSubview:g_assist_label];
        g_assist_panel.contentView = bg;
    }

    g_assist_label.stringValue = text ?: @"";
    g_assist_label.textColor = accent ?: [NSColor whiteColor];

    if (!g_assist_visible) {
        NSScreen *screen = active_screen_on_main();
        if (screen) {
            NSRect sf = screen.visibleFrame;
            NSRect wf = g_assist_panel.frame;
            CGFloat x = sf.origin.x + (sf.size.width - wf.size.width) * 0.5;
            CGFloat y = sf.origin.y + sf.size.height - wf.size.height - 12.0;
            [g_assist_panel setFrameOrigin:NSMakePoint(x, y)];
        }
        [g_assist_panel orderFrontRegardless];
        g_assist_visible = YES;
    }
}

void apply_lightbar_border_on_main(uint8_t r, uint8_t g, uint8_t b) {
    if (!g_hud_visible || g_hud_bg_view == nil) return;
    if ((int)r + (int)g + (int)b < 24) {
        g_hud_bg_view.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.14].CGColor;
        g_hud_bg_view.layer.borderWidth = 0.75;
    } else {
        g_hud_bg_view.layer.borderColor = [NSColor colorWithRed:(CGFloat)r / 255.0
                                                          green:(CGFloat)g / 255.0
                                                           blue:(CGFloat)b / 255.0
                                                          alpha:0.72].CGColor;
        g_hud_bg_view.layer.borderWidth = 1.35;
    }
}

/* ==================== Bottom-Center Live PS -> Keyboard Prompt Bar ==================== */

NSString *keycode_short_label(int code) {
    switch (code) {
        case PSR_KEY_LMB: return @"Tık";
        case PSR_KEY_RMB: return @"SağTık";
        case PSR_KEY_MMB: return @"OrtaTık";
        case PSR_KEY_MOUSE4: return @"M4";
        case PSR_KEY_MOUSE5: return @"M5";
        case 0: return @"A";
        case 1: return @"S";
        case 2: return @"D";
        case 3: return @"F";
        case 4: return @"H";
        case 5: return @"G";
        case 6: return @"Z";
        case 7: return @"X";
        case 8: return @"C";
        case 9: return @"V";
        case 11: return @"B";
        case 12: return @"Q";
        case 13: return @"W";
        case 14: return @"E";
        case 15: return @"R";
        case 16: return @"Y";
        case 17: return @"T";
        case 18: return @"1";
        case 19: return @"2";
        case 20: return @"3";
        case 21: return @"4";
        case 22: return @"6";
        case 23: return @"5";
        case 24: return @"=";
        case 25: return @"9";
        case 26: return @"7";
        case 27: return @"-";
        case 28: return @"8";
        case 29: return @"0";
        case 30: return @"]";
        case 31: return @"O";
        case 32: return @"U";
        case 33: return @"[";
        case 34: return @"I";
        case 35: return @"P";
        case 36: return @"⏎";
        case 37: return @"L";
        case 38: return @"J";
        case 40: return @"K";
        case 41: return @";";
        case 42: return @"\\";
        case 45: return @"N";
        case 46: return @"M";
        case 48: return @"Tab";
        case 49: return @"Space";
        case 50: return @"`";
        case 51: return @"⌫";
        case 53: return @"Esc";
        case 56:
        case 60: return @"Shift";
        case 57: return @"Caps";
        case 58:
        case 61: return @"Opt";
        case 59:
        case 62: return @"Ctrl";
        case 123: return @"←";
        case 124: return @"→";
        case 125: return @"↓";
        case 126: return @"↑";
        default: return @"?";
    }
}

int binding_display_priority(int code) {
    switch (code) {
        /* Primary ergonomic MacBook keys preferred over secondary/fallback bindings */
        case 49: /* Space */
        case 48: /* Tab */
        case 56: /* LeftShift */
        case 59: /* LeftControl */
        case PSR_KEY_LMB:
        case 13: /* W */
        case 1:  /* S */
        case 12: /* Q */
        case 14: /* E */
        case 15: /* R */
        case 3:  /* F */
        case 8:  /* C */
        case 11: /* B */
        case 46: /* M */
        case 18: /* 1 */
        case 19: /* 2 */
        case 20: /* 3 */
        case 21: /* 4 */
            return 3;
        case 36: /* Return */
        case 51: /* Backspace */
        case 123: /* Left */
        case 124: /* Right */
        case 125: /* Down */
        case 126: /* Up */
            return 1;
        default:
            return 2;
    }
}

NSString *find_key_for_target(const PsrBinding *list, int count, PsrTarget target, NSString *fallback) {
    int best_code = -1;
    int best_prio = -1;
    for (int i = 0; i < count; i++) {
        if (list[i].target == target) {
            int prio = binding_display_priority(list[i].input_code);
            if (prio > best_prio) {
                best_prio = prio;
                best_code = list[i].input_code;
            }
        }
    }
    if (best_code >= 0) {
        return keycode_short_label(best_code);
    }
    return fallback;
}

void append_ps_chip(NSMutableAttributedString *out,
                           BOOL need_sep,
                           NSString *psGlyph,
                           NSColor *psColor,
                           NSString *macKey,
                           NSString *hint) {
    NSFont *psFont   = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    NSFont *keyFont  = [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold];
    NSFont *hintFont = [NSFont systemFontOfSize:9.8 weight:NSFontWeightMedium];
    NSColor *keyCol  = [NSColor colorWithRed:0.46 green:0.88 blue:1.0 alpha:1.0];
    NSColor *hintCol = [NSColor colorWithWhite:0.84 alpha:0.92];
    NSColor *sepCol  = [NSColor colorWithWhite:0.46 alpha:0.75];

    if (need_sep) {
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:@" · "
                attributes:@{NSFontAttributeName: hintFont, NSForegroundColorAttributeName: sepCol}]];
    }
    if (psGlyph.length > 0) {
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:psGlyph
                attributes:@{NSFontAttributeName: psFont, NSForegroundColorAttributeName: psColor}]];
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:@" "
                attributes:@{NSFontAttributeName: hintFont, NSForegroundColorAttributeName: sepCol}]];
    }
    if (macKey.length > 0) {
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:macKey
                attributes:@{NSFontAttributeName: keyFont, NSForegroundColorAttributeName: keyCol}]];
    }
    if (hint.length > 0) {
        NSString *suffix = [NSString stringWithFormat:@":%@", hint];
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:suffix
                attributes:@{NSFontAttributeName: hintFont, NSForegroundColorAttributeName: hintCol}]];
    }
}

void refresh_prompt_bar_on_main(bool capture_active, int mode_id, bool aiming, bool smart_mode) {
    int input_source = atomic_load(&g_input_source);
    BOOL phys_mode = (input_source == 1 && atomic_load(&g_phys_connected));
    BOOL should_show = (capture_active && !phys_mode && g_prompt_enabled && atomic_load(&g_app_active));

    if (!should_show) {
        if (g_prompt_panel != nil && g_prompt_visible) {
            [g_prompt_panel orderOut:nil];
            g_prompt_visible = NO;
        }
        return;
    }

    PsrConfig cfg;
    bool has_cfg = false;
    pthread_mutex_lock(&g_lock);
    if (g_mapper) {
        cfg = g_mapper->cfg;
        has_cfg = true;
    }
    pthread_mutex_unlock(&g_lock);
    if (!has_cfg) return;

    NSColor *cCross    = [NSColor colorWithRed:0.42 green:0.74 blue:1.0  alpha:1.0];
    NSColor *cCircle   = [NSColor colorWithRed:1.0  green:0.44 blue:0.44 alpha:1.0];
    NSColor *cSquare   = [NSColor colorWithRed:0.92 green:0.56 blue:0.98 alpha:1.0];
    NSColor *cTriangle = [NSColor colorWithRed:0.36 green:0.94 blue:0.68 alpha:1.0];
    NSColor *cNeutral  = [NSColor colorWithWhite:0.94 alpha:0.96];
    NSColor *cSep      = [NSColor colorWithWhite:0.44 alpha:0.75];

    NSFont *badgeFont = [NSFont systemFontOfSize:10.0 weight:NSFontWeightHeavy];
    NSMutableAttributedString *str = [[NSMutableAttributedString alloc] init];

    NSString *badgeText;
    NSColor *badgeCol;
    if (mode_id == 2) {
        badgeText = @"✈ UÇAK";
        badgeCol  = [NSColor colorWithRed:0.80 green:0.64 blue:1.0 alpha:1.0];
    } else if (mode_id == 1) {
        badgeText = @"🚗 ARAÇ";
        badgeCol  = [NSColor colorWithRed:1.0 green:0.74 blue:0.36 alpha:1.0];
    } else if (aiming) {
        badgeText = @"🎯 NİŞAN";
        badgeCol  = [NSColor colorWithRed:1.0 green:0.84 blue:0.38 alpha:1.0];
    } else {
        badgeText = @"YAYA";
        badgeCol  = [NSColor colorWithRed:0.48 green:0.88 blue:1.0 alpha:1.0];
    }

    [str appendAttributedString:[[NSAttributedString alloc]
        initWithString:badgeText
            attributes:@{NSFontAttributeName: badgeFont, NSForegroundColorAttributeName: badgeCol}]];
    [str appendAttributedString:[[NSAttributedString alloc]
        initWithString:@" │ "
            attributes:@{NSFontAttributeName: badgeFont, NSForegroundColorAttributeName: cSep}]];

    if (mode_id == 2) {
        /* GTA 6 Aircraft Mode */
        NSString *kR2  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_TRIGGER_R2, @"W");
        NSString *kL2  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_TRIGGER_L2, @"S");
        NSString *kSq  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_BTN_SQUARE, @"Q");
        NSString *kCi  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_BTN_CIRCLE, @"E");
        NSString *kR1  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_BTN_R1, @"Space");
        NSString *kL1  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_BTN_L1, @"Tab");
        NSString *kL3  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_BTN_L3, @"R");
        NSString *kTr  = find_key_for_target(cfg.aircraft, cfg.aircraft_count, PSR_BTN_TRIANGLE, @"F");
        NSString *kCrs = keycode_short_label(cfg.cruise_toggle_key);

        append_ps_chip(str, NO,  @"R2/L2", cNeutral,  [NSString stringWithFormat:@"%@/%@", kR2, kL2], @"Gaz");
        append_ps_chip(str, YES, @"L",     cNeutral,  @"↑↓←→", @"Uçuş");
        append_ps_chip(str, YES, @"▢",     cSquare,   kSq, @"SolDümen");
        append_ps_chip(str, YES, @"◯",     cCircle,   kCi, @"SağDümen");
        append_ps_chip(str, YES, @"R1",    cNeutral,  kR1, @"Ateş");
        append_ps_chip(str, YES, @"L1",    cNeutral,  kL1, @"Silah");
        append_ps_chip(str, YES, @"L3",    cNeutral,  kL3, @"Teker");
        append_ps_chip(str, YES, @"△",     cTriangle, kTr, @"Atla");
        append_ps_chip(str, YES, @"",      cNeutral,  kCrs, @"Seyir");
    } else if (mode_id == 1) {
        /* GTA 6 Land / Water / Bicycle Vehicle Mode */
        NSString *kR2 = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_TRIGGER_R2, @"W");
        NSString *kL2 = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_TRIGGER_L2, @"S");
        NSString *kCr = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_CROSS, @"Space");
        NSString *kR1 = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_R1, @"Tık");
        NSString *kCi = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_CIRCLE, @"C");
        NSString *kSq = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_SQUARE, @"R");
        NSString *kL1 = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_L1, @"Tab");
        NSString *kL3 = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_L3, @"Shift");
        NSString *kTr = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_TRIANGLE, @"F");
        NSString *kR3 = find_key_for_target(cfg.vehicle, cfg.vehicle_count, PSR_BTN_R3, @"B");

        append_ps_chip(str, NO,  @"R2/L2", cNeutral,  [NSString stringWithFormat:@"%@/%@", kR2, kL2], @"Gaz/Fren");
        append_ps_chip(str, YES, @"✕",     cCross,    kCr, @"ElFreni/Hız");
        append_ps_chip(str, YES, @"R1",    cNeutral,  kR1, @"Ateş");
        append_ps_chip(str, YES, @"◯",     cCircle,   kCi, @"Far/Eğil");
        append_ps_chip(str, YES, @"▢",     cSquare,   kSq, @"Vur");
        append_ps_chip(str, YES, @"L1",    cNeutral,  kL1, @"Silah");
        append_ps_chip(str, YES, @"L3",    cNeutral,  kL3, @"Korna");
        append_ps_chip(str, YES, @"△",     cTriangle, kTr, @"İn");
        append_ps_chip(str, YES, @"R3",    cNeutral,  kR3, @"Arka");
        append_ps_chip(str, YES, @"✚",     cNeutral,  @"1-4", @"");
    } else if (aiming) {
        /* GTA 6 Aiming Context (auto-switches the instant L2 is held!) */
        NSString *kR2  = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_TRIGGER_R2, @"Tık");
        NSString *kR1  = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_R1, @"Q");
        NSString *kTr  = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_TRIANGLE, @"E");
        NSString *kSq  = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_SQUARE, @"R");
        NSString *kR3  = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_R3, @"B");
        NSString *kCr  = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_CROSS, @"Space");
        NSString *kDpl = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_DPAD_LEFT, @"4");
        NSString *kSn  = keycode_short_label(cfg.walk_mod_key);

        append_ps_chip(str, NO,  @"R2", cNeutral,  kR2, @"Ateş");
        append_ps_chip(str, YES, @"R1", cNeutral,  kR1, @"HızlıAt");
        append_ps_chip(str, YES, @"△",  cTriangle, kTr, @"SilahDeğiş");
        append_ps_chip(str, YES, @"▢",  cSquare,   kSq, @"Şarjör");
        append_ps_chip(str, YES, @"R3", cNeutral,  kR3, @"Zoom");
        append_ps_chip(str, YES, @"←",  cNeutral,  smart_mode ? @"V" : kDpl, @"Omuz");
        append_ps_chip(str, YES, @"",   cNeutral,  @"2P", @"Dürbün");
        append_ps_chip(str, YES, @"",   cNeutral,  kSn, @"Sniper");
        append_ps_chip(str, YES, @"✕",  cCross,    kCr, @"Takla");
    } else {
        /* GTA 6 On-Foot Context */
        NSString *kCr = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_CROSS, @"Space");
        NSString *kCi = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_CIRCLE, @"C");
        NSString *kSq = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_SQUARE, @"R");
        NSString *kTr = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_TRIANGLE, @"E");
        NSString *kL1 = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_L1, @"Tab");
        NSString *kR1 = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_R1, @"Q");
        NSString *kL2 = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_TRIGGER_L2, @"Ctrl");
        NSString *kR2 = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_TRIGGER_R2, @"Tık");
        NSString *kL3 = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_L3, @"Shift");
        NSString *kR3 = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_R3, @"B");
        NSString *kTp = find_key_for_target(cfg.on_foot, cfg.on_foot_count, PSR_BTN_TOUCHPAD, @"M");

        append_ps_chip(str, NO,  @"✕",  cCross,    kCr, @"Zıpla");
        append_ps_chip(str, YES, @"◯",  cCircle,   kCi, @"Eğil");
        append_ps_chip(str, YES, @"▢",  cSquare,   kSq, @"Dövüş");
        append_ps_chip(str, YES, @"△",  cTriangle, smart_mode ? [NSString stringWithFormat:@"%@/F", kTr] : kTr, @"Bin");
        append_ps_chip(str, YES, @"L1", cNeutral,  kL1, @"Silah");
        append_ps_chip(str, YES, @"R1", cNeutral,  kR1, @"Siper");
        append_ps_chip(str, YES, @"L2", cNeutral,  kL2, @"Nişan");
        append_ps_chip(str, YES, @"R2", cNeutral,  kR2, @"Ateş");
        append_ps_chip(str, YES, @"L3", cNeutral,  kL3, @"Koş");
        append_ps_chip(str, YES, @"R3", cNeutral,  kR3, @"Arka");
        append_ps_chip(str, YES, @"▭",  cNeutral,  kTp, @"Map");
        append_ps_chip(str, YES, @"✚",  cNeutral,  @"1-4", @"");
    }

    NSScreen *screen = active_screen_on_main();
    NSRect sf = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    NSSize textSz = [str size];
    CGFloat barH = 26.0;
    CGFloat maxW = sf.size.width - 36.0;
    CGFloat barW = ceil(textSz.width) + 28.0;
    if (barW < 420.0) barW = 420.0;
    if (barW > maxW) barW = maxW;

    if (g_prompt_panel == nil) {
        g_prompt_panel = create_overlay_panel(NSMakeRect(0, 0, barW, barH));
        NSView *bg = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, barW, barH)];
        bg.wantsLayer = YES;
        bg.layer.cornerRadius = 13.0;
        bg.layer.backgroundColor = [NSColor colorWithRed:0.04 green:0.05 blue:0.08 alpha:0.74].CGColor;
        bg.layer.borderWidth = 0.75;
        bg.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;

        g_prompt_label = make_label(
            @"",
            [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium],
            [NSColor whiteColor],
            NSTextAlignmentCenter
        );
        g_prompt_label.frame = NSMakeRect(10, 4, barW - 20, 17);
        [bg addSubview:g_prompt_label];
        g_prompt_panel.contentView = bg;
    }

    g_prompt_panel.contentView.frame = NSMakeRect(0, 0, barW, barH);
    g_prompt_label.frame = NSMakeRect(10, 4, barW - 20, 17);
    g_prompt_label.attributedStringValue = str;

    if (aiming && mode_id == 0) {
        g_prompt_panel.contentView.layer.borderColor = [NSColor colorWithRed:1.0 green:0.82 blue:0.36 alpha:0.55].CGColor;
    } else if (mode_id == 2) {
        g_prompt_panel.contentView.layer.borderColor = [NSColor colorWithRed:0.74 green:0.54 blue:1.0 alpha:0.45].CGColor;
    } else if (mode_id == 1) {
        g_prompt_panel.contentView.layer.borderColor = [NSColor colorWithRed:1.0 green:0.68 blue:0.28 alpha:0.45].CGColor;
    } else {
        g_prompt_panel.contentView.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;
    }

    CGFloat x = sf.origin.x + (sf.size.width - barW) * 0.5;
    CGFloat y = sf.origin.y + 10.0;
    [g_prompt_panel setFrame:NSMakeRect(x, y, barW, barH) display:YES];
    if (!g_prompt_visible) {
        [g_prompt_panel orderFrontRegardless];
        g_prompt_visible = YES;
    }
}

/* ==================== Compact Top-Right Controls HUD ==================== */

void rebuild_hud_content_on_main(bool capture_active, int mode_id, bool smart_mode) {
    int input_source = atomic_load(&g_input_source);
    BOOL phys_mode = (input_source == 1 && atomic_load(&g_phys_connected));
    NSArray<NSArray<NSString *> *> *rows;
    NSString *physBatteryText = nil;
    NSString *physCtrlName = @"DUALSENSE";

    if (phys_mode) {
        pthread_mutex_lock(&g_phys_lock);
        GCController *ctrl = g_phys_controller;
        if (ctrl != nil) {
            if (ctrl.vendorName.length > 0) {
                physCtrlName = ctrl.vendorName;
            }
            if (ctrl.battery != nil && ctrl.battery.batteryLevel >= 0.0f) {
                int pct = (int)lroundf(ctrl.battery.batteryLevel * 100.0f);
                NSString *chg = (ctrl.battery.batteryState == GCDeviceBatteryStateCharging) ? @" ⚡" : @"";
                physBatteryText = [NSString stringWithFormat:@"%d%%%@", pct, chg];
            }
        }
        pthread_mutex_unlock(&g_phys_lock);

        rows = @[
            @[@"Durum",        physBatteryText ? [NSString stringWithFormat:@"%@ · Pil %@", physCtrlName, physBatteryText]
                                               : [NSString stringWithFormat:@"%@ · Aktif", physCtrlName]],
            @[@"0 (Sıfır)",    @"Trackpad + Klavye'ye Anında Geç"],
            @[@";",            @"Canlı Ping / Jitter / AWDL Göster"],
            @[@"[",            @"PS5 Mikrofon Sustur (Mic Mute)"],
            @[@"H",            @"Bu HUD Panelini Gizle / Göster"],
            @[@"Otomatik",     @"Kola dokununca otomatik DualSense"],
        ];
    } else if (mode_id == 2) {
        /* GTA 6 Official Aircraft / Helicopter Mode */
        rows = @[
            @[@"W / S",          @"Gaz-Yüksel (R2) · İniş (L2)"],
            @[@"↑ ↓ ← →",        @"Pitch & Roll (2-El Uçuş Kolu)"],
            @[@"A / D · Shf/C",  smart_mode ? @"Tek-El Roll & Pitch (Yumuşak)" : @"Tek-El Roll & Pitch (Ham)"],
            @[@"Q / E",          @"Sol Dümen (▢) · Sağ Dümen (◯)"],
            @[@"Space / Tık",    @"Silah Ateşle (R1)"],
            @[@"Tab / Ctrl",     @"Silah Kılıfla / Çark (L1)"],
            @[@"R / F",          @"İniş Takımı (L3) · Atla (△)"],
            @[@"] / M / B",      @"Oto-Uçuş · Harita · Arka (R3)"],
            @[@"1 2 3 4 / 2P",   @"D-Pad (↑→↓←) · 2P: Swipe"],
            @[@"\\ / - = / ;",   @"Alt Çubuk · Hassas. · Ping"],
        ];
    } else if (mode_id == 1) {
        /* GTA 6 Official Land / Water / Bicycle Vehicle Mode */
        rows = @[
            @[@"W / S",          @"Gaz (R2) · Fren / Geri (L2)"],
            @[@"A / D",          smart_mode ? @"Yumuşak Direksiyon" : @"Direksiyon (Ham)"],
            @[@"Space",          @"El Freni / Bisiklet Hız (✕)"],
            @[@"Tık / Q",        @"Araçtan Ateş (R1)"],
            @[@"Tab / Ctrl",     smart_mode ? @"Silah Çarkı / Kılıfla (L1)" : @"Silah Kılıfla (L1)"],
            @[@"C / R",          @"Far-Eğil-Zıpla (◯) · Vur (▢)"],
            @[@"Shift / E",      @"Korna / Nitro / Zil (L3)"],
            @[@"F",              smart_mode ? @"(△) İn + Oto-Yaya" : @"(△) Araçtan İn"],
            @[@"B / M / 1-4",    @"Arka (R3) · Harita · D-Pad"],
            @[@"U / I / L / ]",  @"Hotwire◡ · 360°↻ · Hızlı✕ · Hız"],
            @[@"O / \\ / ;",     @"Uçak · Alt Çubuk · Ping"],
        ];
    } else {
        /* GTA 6 Official On-Foot / Aiming / Melee / Swim Mode */
        rows = @[
            @[@"W A S D · Z",    @"Hareket · Yürü / Sniper Zoom"],
            @[@"Trackpad / 2P",  @"Kamera · 2P: Swipe / L2+Dürbün"],
            @[@"Tık / J",        @"Ateş / Saldırı — R2"],
            @[@"Ctrl / SağTık",  @"Nişan (L2) · +V: Omuz · +Z: Sniper"],
            @[@"Shift / ]",      @"Koş (L3) · Oto-Koş"],
            @[@"Space / ⏎",      @"✕ / Zıpla-Tırman / Yüzme"],
            @[@"C / ⌫",          @"◯ / Çömel / Tekme / Geri"],
            @[@"R / V",          smart_mode ? @"▢ Şarjör/Dövüş (Nişan V: Omuz)" : @"▢ / Şarjör / Dövüş"],
            @[@"E / F",          smart_mode ? @"△ Etkil. · F: Bin (Oto-Araç)" : @"△ / Etkileşim / Bin"],
            @[@"Q / Tab",        smart_mode ? @"Siper/At (R1) · Silah Çarkı (L1)" : @"Siper (R1) · Silah (L1)"],
            @[@"U / I / Y / L",  @"Hotwire◡ · 360°↻ · R · Hızlı✕"],
            @[@"M / Esc / B",    @"Harita (▭) · Pause · Zoom (R3)"],
            @[@"1 2 3 4 / Ok",   @"D-Pad (↑ → ↓ ←)"],
            @[@"\\ / - = / ;",   @"Alt Çubuk · Hassas. · Ping"],
        ];
    }

    CGFloat winW = 298.0;
    CGFloat rowH = 16.5;
    CGFloat headerH = 28.0;
    CGFloat footerH = 22.0;
    CGFloat padV = 10.0;
    CGFloat winH = headerH + footerH + padV + (CGFloat)rows.count * rowH;

    if (g_hud_panel == nil) {
        g_hud_panel = create_overlay_panel(NSMakeRect(0, 0, winW, winH));
        g_hud_panel.alphaValue = 0.88;
    }

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 11.0;
    bg.layer.masksToBounds = YES;
    bg.layer.borderWidth = 0.75;
    bg.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.14].CGColor;
    bg.layer.backgroundColor = [NSColor colorWithRed:0.04 green:0.05 blue:0.08 alpha:0.60].CGColor;
    g_hud_bg_view = bg;

    /* Compact single-line header */
    NSView *hdr = [[NSView alloc] initWithFrame:NSMakeRect(0, winH - headerH, winW, headerH)];
    hdr.wantsLayer = YES;
    if (phys_mode) {
        hdr.layer.backgroundColor = [NSColor colorWithRed:0.10 green:0.62 blue:0.42 alpha:0.36].CGColor;
    } else if (mode_id == 2) {
        hdr.layer.backgroundColor = [NSColor colorWithRed:0.55 green:0.32 blue:0.88 alpha:0.36].CGColor;
    } else if (mode_id == 1) {
        hdr.layer.backgroundColor = [NSColor colorWithRed:0.85 green:0.48 blue:0.12 alpha:0.32].CGColor;
    } else {
        hdr.layer.backgroundColor = [NSColor colorWithRed:0.16 green:0.52 blue:0.86 alpha:0.30].CGColor;
    }
    [bg addSubview:hdr];

    NSString *modeTitle;
    if (phys_mode) {
        modeTitle = @"DUALSENSE · HİBRİT";
    } else if (mode_id == 2) {
        modeTitle = smart_mode ? @"UÇAK · ✦AKILLI" : @"UÇAK MODU";
    } else if (mode_id == 1) {
        modeTitle = smart_mode ? @"ARAÇ · ✦AKILLI" : @"ARAÇ MODU";
    } else {
        modeTitle = smart_mode ? @"YAYA · ✦AKILLI" : @"YAYA MODU";
    }

    NSTextField *titleLbl = make_label(
        modeTitle,
        [NSFont systemFontOfSize:11.0 weight:NSFontWeightBold],
        [NSColor colorWithWhite:0.98 alpha:1.0],
        NSTextAlignmentLeft
    );
    titleLbl.frame = NSMakeRect(10, 6, 158, 15);
    [hdr addSubview:titleLbl];

    NSString *capBadge = phys_mode
        ? (physBatteryText ? [NSString stringWithFormat:@"● %@", physBatteryText] : @"● KOL AKTİF")
        : (capture_active ? @"● AKTİF" : @"○ KAPALI ('0')");
    NSColor *capColor = (phys_mode || capture_active)
        ? [NSColor colorWithRed:0.42 green:0.96 blue:0.62 alpha:1.0]
        : [NSColor colorWithRed:1.0 green:0.70 blue:0.36 alpha:1.0];
    NSTextField *capLbl = make_label(
        capBadge,
        [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold],
        capColor,
        NSTextAlignmentRight
    );
    capLbl.frame = NSMakeRect(168, 7, winW - 178, 14);
    [hdr addSubview:capLbl];

    NSFont *keyFont = [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightSemibold];
    NSFont *descFont = [NSFont systemFontOfSize:10.0 weight:NSFontWeightRegular];
    NSColor *keyColor = [NSColor colorWithRed:0.48 green:0.85 blue:1.0 alpha:0.96];
    NSColor *descColor = [NSColor colorWithWhite:0.90 alpha:0.94];

    CGFloat y = winH - headerH - 5.0 - rowH;
    for (NSArray<NSString *> *pair in rows) {
        NSTextField *kLbl = make_label(pair[0], keyFont, keyColor, NSTextAlignmentLeft);
        kLbl.frame = NSMakeRect(10, y, 102, rowH);
        [bg addSubview:kLbl];

        NSTextField *dLbl = make_label(pair[1], descFont, descColor, NSTextAlignmentLeft);
        dLbl.frame = NSMakeRect(114, y, winW - 122, rowH);
        [bg addSubview:dLbl];
        y -= rowH;
    }

    /* Minimal footer bar */
    NSTextField *footer = make_label(
        phys_mode
            ? @"0:Trackpad · ;:Ping · [:Mic · H:Gizle"
            : @"0:İmleç · G:Araç · O:Uçak · \\:AltÇubuk · H:Gizle",
        [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightMedium],
        [NSColor colorWithRed:1.0 green:0.86 blue:0.48 alpha:0.86],
        NSTextAlignmentCenter
    );
    footer.frame = NSMakeRect(6, 4, winW - 12, 14);
    [bg addSubview:footer];

    /* Anchor cleanly to top-right corner (never blocks crosshair or bottom-left minimap) */
    NSScreen *screen = active_screen_on_main();
    NSRect frame = NSMakeRect(0, 0, winW, winH);
    if (screen) {
        NSRect sf = screen.visibleFrame;
        frame.origin.x = sf.origin.x + sf.size.width - winW - 16.0;
        frame.origin.y = sf.origin.y + sf.size.height - winH - 16.0;
    }

    g_hud_panel.contentView = bg;
    [g_hud_panel setFrame:frame display:YES];
    g_hud_last_mode = mode_id;
    g_hud_last_capture = capture_active ? YES : NO;
    g_hud_last_smart = smart_mode ? YES : NO;
    g_hud_last_source = phys_mode ? 1 : 0;

    if (g_has_led_color) {
        apply_lightbar_border_on_main(g_last_led_r, g_last_led_g, g_last_led_b);
    }
}

void set_hud_visible_on_main(BOOL visible, bool capture_active, int mode_id, bool smart_mode) {
    if (visible) {
        if (g_toast_panel != nil) {
            ++g_toast_gen;
            [g_toast_panel orderOut:nil];
        }
        rebuild_hud_content_on_main(capture_active, mode_id, smart_mode);
        [g_hud_panel orderFrontRegardless];
        g_hud_visible = YES;
        fprintf(stderr, "[senza] Compact HUD ON  (top-right, press 'H' to hide)\n");
        fflush(stderr);
    } else if (g_hud_panel != nil && g_hud_visible) {
        [g_hud_panel orderOut:nil];
        g_hud_visible = NO;
        fprintf(stderr, "[senza] Compact HUD OFF\n");
        fflush(stderr);
    }
}
