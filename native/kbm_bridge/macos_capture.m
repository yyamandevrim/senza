#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#include "macos_capture.h"

#include <ctype.h>
#include <ifaddrs.h>
#include <mach/mach_time.h>
#include <math.h>
#include <net/if.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PSR_HUD_KEY_H 4           /* macOS virtual keycode for 'H' */
#define PSR_NET_KEY_SEMICOLON 41  /* macOS virtual keycode for ';' (live ping/AWDL overlay) */

static PsrMapper *g_mapper = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool g_running = false;
static atomic_bool g_cursor_locked = false;
static atomic_bool g_app_active = true;

static id g_local_monitor = nil;
static id g_resign_observer = nil;
static id g_become_observer = nil;

static mach_timebase_info_data_t g_cap_timebase = {0, 0};
static uint64_t g_last_haptic_ns = 0;
static uint64_t g_last_assist_ui_ns = 0;
static uint8_t g_last_led_r = 0;
static uint8_t g_last_led_g = 0;
static uint8_t g_last_led_b = 0;
static bool g_has_led_color = false;

static uint64_t cap_now_ns(void) {
    if (g_cap_timebase.denom == 0) {
        mach_timebase_info(&g_cap_timebase);
    }
    return (mach_absolute_time() * g_cap_timebase.numer) / g_cap_timebase.denom;
}

/* Non-activating, click-through, fullscreen-safe overlay panel */
@interface PsrHudPanel : NSPanel
@end

@implementation PsrHudPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

/* Compact top-right Controls HUD (only active mode, low visual footprint) */
static PsrHudPanel *g_hud_panel = nil;
static NSView *g_hud_bg_view = nil;
static BOOL g_hud_visible = NO;
static int g_hud_last_mode = 0; /* 0=on-foot, 1=vehicle, 2=aircraft */
static BOOL g_hud_last_capture = NO;
static BOOL g_hud_last_smart = YES;

/* Micro top-center status pill (auto-fades in 1.6s on toggles/adjustments) */
static PsrHudPanel *g_toast_panel = nil;
static NSTextField *g_toast_label = nil;
static uint64_t g_toast_gen = 0;

/* Live top-center minigame assist pill (visible ONLY while holding U, I, Y, or L) */
static PsrHudPanel *g_assist_panel = nil;
static NSTextField *g_assist_label = nil;
static BOOL g_assist_visible = NO;
static int g_prev_assist_kind = 0; /* 0=none, 1=hotwire, 2=circle, 3=sticky, 4=rapid */

/* Ultra-slim top-left live Network / Ping / AWDL telemetry pill (toggled with ';') */
static PsrHudPanel *g_net_panel = nil;
static NSTextField *g_net_label = nil;
static atomic_bool g_net_visible = false;
static atomic_bool g_net_thread_active = false;
static pthread_t g_net_thread;

static int current_mode_id(bool vehicle_mode, bool aircraft_mode) {
    if (aircraft_mode) return 2;
    if (vehicle_mode) return 1;
    return 0;
}

static NSTextField *make_label(NSString *text, NSFont *font, NSColor *color, NSTextAlignment align) {
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

static PsrHudPanel *create_overlay_panel(NSRect rect) {
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

static NSScreen *active_screen_on_main(void) {
    return [NSApp keyWindow].screen ?: [NSScreen mainScreen];
}

/* ==================== Live Sensitivity Auto-Save ==================== */

static void persist_sensitivity_async(float new_sens) {
    const char *json_env = getenv("DUALMAC_PROFILE_JSON");
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

/* ==================== Live Network / AWDL Telemetry ==================== */

static bool check_awdl_is_up(void) {
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0 || !ifap) return false;
    bool up = false;
    for (struct ifaddrs *ifa = ifap; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_name && strcmp(ifa->ifa_name, "awdl0") == 0) {
            if ((ifa->ifa_flags & IFF_UP) != 0) {
                up = true;
            }
            break;
        }
    }
    freeifaddrs(ifap);
    return up;
}

static void sanitize_ping_host(char *out, size_t out_sz) {
    const char *env = getenv("DUALMAC_PING_HOST");
    if (!env || env[0] == '\0') {
        snprintf(out, out_sz, "1.1.1.1");
        return;
    }
    size_t j = 0;
    for (size_t i = 0; env[i] != '\0' && j + 1 < out_sz; i++) {
        unsigned char c = (unsigned char)env[i];
        if (isalnum(c) || c == '.' || c == '-' || c == ':') {
            out[j++] = (char)c;
        }
    }
    out[j] = '\0';
    if (j == 0) {
        snprintf(out, out_sz, "1.1.1.1");
    }
}

static void update_net_pill_on_main(NSString *text, NSColor *color) {
    if (!atomic_load(&g_net_visible) || g_net_panel == nil || g_net_label == nil) return;
    g_net_label.stringValue = text;
    g_net_label.textColor = color;
}

static void *net_telemetry_thread(void *arg) {
    (void)arg;
    char host[128];
    sanitize_ping_host(host, sizeof(host));

    while (atomic_load(&g_net_visible) && atomic_load(&g_running)) {
        bool awdl_up = check_awdl_is_up();

        char cmd[256];
        snprintf(cmd, sizeof(cmd), "/sbin/ping -c 3 -i 0.2 -W 450 %s 2>/dev/null", host);
        FILE *fp = popen(cmd, "r");

        double avg_ms = -1.0;
        double jitter_ms = 0.0;
        double loss_pct = 100.0;

        if (fp) {
            char line[512];
            while (fgets(line, sizeof(line), fp)) {
                char *loss_p = strstr(line, "% packet loss");
                if (loss_p) {
                    char *scan = loss_p;
                    while (scan > line && (isdigit((unsigned char)*(scan - 1)) || *(scan - 1) == '.')) {
                        scan--;
                    }
                    loss_pct = strtod(scan, NULL);
                }
                char *eq = strstr(line, "min/avg/max/stddev = ");
                if (eq) {
                    double mn = 0, av = 0, mx = 0, sd = 0;
                    if (sscanf(eq + 21, "%lf/%lf/%lf/%lf", &mn, &av, &mx, &sd) == 4) {
                        avg_ms = av;
                        jitter_ms = sd;
                    }
                }
            }
            pclose(fp);
        }

        if (!atomic_load(&g_net_visible) || !atomic_load(&g_running)) break;

        NSString *text = nil;
        NSColor *col = nil;
        const char *awdl_str = awdl_up ? "AWDL ON!" : "AWDL OFF";

        if (avg_ms < 0.0) {
            text = [NSString stringWithFormat:@"● PING YOK · %s", awdl_str];
            col = [NSColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
        } else {
            text = [NSString stringWithFormat:@"● %.0fms · ±%.1fms · %.0f%% · %s",
                    avg_ms, jitter_ms, loss_pct, awdl_str];
            if (loss_pct > 0.5 || avg_ms >= 75.0 || awdl_up) {
                col = [NSColor colorWithRed:1.0 green:0.48 blue:0.42 alpha:1.0];
            } else if (avg_ms >= 35.0 || jitter_ms >= 8.0) {
                col = [NSColor colorWithRed:1.0 green:0.80 blue:0.38 alpha:1.0];
            } else {
                col = [NSColor colorWithRed:0.44 green:0.96 blue:0.64 alpha:1.0];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            update_net_pill_on_main(text, col);
        });

        /* Sleep 2.0s in 100ms chunks so stopping is instantaneous */
        for (int i = 0; i < 20; i++) {
            if (!atomic_load(&g_net_visible) || !atomic_load(&g_running)) break;
            usleep(100000);
        }
    }

    atomic_store(&g_net_thread_active, false);
    return NULL;
}

static void set_net_visible_on_main(BOOL visible) {
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
        fprintf(stderr, "[dualmac] Live Ping/AWDL pill ON  (top-left, press ';' to hide)\n");
        fflush(stderr);
    } else {
        atomic_store(&g_net_visible, false);
        if (g_net_panel != nil) {
            [g_net_panel orderOut:nil];
        }
    }
}

/* ==================== Toasts & Assist Micro-Pill ==================== */

static void show_toast_on_main(NSString *text, NSColor *accent) {
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

static NSString *stick_direction_glyph(float rx, float ry) {
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

static void update_assist_pill_on_main(BOOL visible, NSString *text, NSColor *accent) {
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

static void apply_lightbar_border_on_main(uint8_t r, uint8_t g, uint8_t b) {
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

/* ==================== Compact Top-Right Controls HUD ==================== */

static void rebuild_hud_content_on_main(bool capture_active, int mode_id, bool smart_mode) {
    NSArray<NSArray<NSString *> *> *rows;
    if (mode_id == 2) {
        /* Aircraft / Helicopter Mode */
        rows = @[
            @[@"W / S",          @"Gaz-Yüksel (R2) · İniş (L2)"],
            @[@"A / D",          smart_mode ? @"Yatış / Roll (Yumuşak)" : @"Yatış / Roll (Ham)"],
            @[@"↑↓ / Shift-C",   @"Burun Aşağı / Yukarı (Pitch)"],
            @[@"Q / E (←→)",     @"Dümen Sol (L1) · Sağ (R1)"],
            @[@"Space / Tık",    @"Silah Ateşle (✕)"],
            @[@"Tab / Caps",     @"Silah Değiştir (▢)"],
            @[@"R / F",          @"İniş Takımı (L3) · Atla (△)"],
            @[@"] / M / V",      @"Oto-Uçuş · Harita · Kamera"],
            @[@"2-Parmak",       @"Touchpad Swipe (Hızlı Geçiş)"],
            @[@"- = / [ / ;",    @"Hassas. · Mic Mute · Ping"],
        ];
    } else if (mode_id == 1) {
        /* Land / Water Vehicle Mode */
        rows = @[
            @[@"W / S",          @"Gaz (R2) · Fren (L2)"],
            @[@"A / D",          smart_mode ? @"Yumuşak Direksiyon" : @"Direksiyon (Ham)"],
            @[@"Trackpad / 2P",  @"Kamera · 2P: Touchpad Swipe"],
            @[@"Space",          @"El Freni (R1)"],
            @[@"Tık / Caps",     @"Araçtan Ateş (L1)"],
            @[@"F / E",          smart_mode ? @"(△) İn + Oto-Yaya · Korna" : @"(△) İn · Korna (L3)"],
            @[@"Q / R",          smart_mode ? @"(▢) Radyo Çarkı · Sinematik" : @"(▢) Radyo · (◯) Sinematik"],
            @[@"U / I / Y",      @"Hotwire◡ · 360°↻ · Kalıcı R"],
            @[@"L / ]",          @"Hızlı ✕ · Hız Sabitleyici"],
            @[@"O / M / C",      @"Uçak Modu · Harita · Arka"],
            @[@"- = / [ / ;",    @"Hassas. · Mic Mute · Ping"],
        ];
    } else {
        /* On-Foot GTA 6 Official Default Mode */
        rows = @[
            @[@"W A S D · Z",    @"Hareket · Yürü / Sniper Zoom"],
            @[@"Trackpad / 2P",  @"Kamera · 2P: Swipe / L2+Zoom"],
            @[@"Tık / J",        @"Ateş — R2"],
            @[@"Caps / K",       @"Nişan (L2) · +Z: Keskin Nişan"],
            @[@"Shift / ]",      @"Koş (L3) · Oto-Koş"],
            @[@"Space / ⏎",      @"✕ / Zıpla-Tırman / Onay"],
            @[@"C / ⌫",          @"◯ / Çömel / Geri"],
            @[@"R / V",          @"▢ / Yakın Dövüş / Şarjör"],
            @[@"E / F",          smart_mode ? @"△ Etkil. · F: Bin (Oto-Araç)" : @"△ / Etkileşim / Bin"],
            @[@"Q / Tab",        smart_mode ? @"Siper (R1) · Silah Çarkı" : @"Siper (R1) · Holster (L1)"],
            @[@"U / I / Y / L",  @"Hotwire◡ · 360°↻ · R · Hızlı✕"],
            @[@"M / Esc / B",    @"Harita · Pause · Arka (R3)"],
            @[@"1 2 3 4 / Ok",   @"Tel · Radyo · Map · Patlat"],
            @[@"- = / [ / ;",    @"Hassas. · Mic Mute · Ping"],
        ];
    }

    CGFloat winW = 294.0;
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
    if (mode_id == 2) {
        hdr.layer.backgroundColor = [NSColor colorWithRed:0.55 green:0.32 blue:0.88 alpha:0.36].CGColor;
    } else if (mode_id == 1) {
        hdr.layer.backgroundColor = [NSColor colorWithRed:0.85 green:0.48 blue:0.12 alpha:0.32].CGColor;
    } else {
        hdr.layer.backgroundColor = [NSColor colorWithRed:0.16 green:0.52 blue:0.86 alpha:0.30].CGColor;
    }
    [bg addSubview:hdr];

    NSString *modeTitle;
    if (mode_id == 2) {
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

    NSString *capBadge = capture_active ? @"● AKTİF" : @"○ KAPALI ('0')";
    NSColor *capColor = capture_active
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
        kLbl.frame = NSMakeRect(10, y, 100, rowH);
        [bg addSubview:kLbl];

        NSTextField *dLbl = make_label(pair[1], descFont, descColor, NSTextAlignmentLeft);
        dLbl.frame = NSMakeRect(112, y, winW - 120, rowH);
        [bg addSubview:dLbl];
        y -= rowH;
    }

    /* Minimal footer bar */
    NSTextField *footer = make_label(
        @"0:İmleç · G:Araç · O:Uçak · T:Akıllı · ;:Ping · H:Gizle",
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

    if (g_has_led_color) {
        apply_lightbar_border_on_main(g_last_led_r, g_last_led_g, g_last_led_b);
    }
}

static void set_hud_visible_on_main(BOOL visible, bool capture_active, int mode_id, bool smart_mode) {
    if (visible) {
        if (g_toast_panel != nil) {
            ++g_toast_gen;
            [g_toast_panel orderOut:nil];
        }
        rebuild_hud_content_on_main(capture_active, mode_id, smart_mode);
        [g_hud_panel orderFrontRegardless];
        g_hud_visible = YES;
        fprintf(stderr, "[dualmac] Compact HUD ON  (top-right, press 'H' to hide)\n");
        fflush(stderr);
    } else if (g_hud_panel != nil && g_hud_visible) {
        [g_hud_panel orderOut:nil];
        g_hud_visible = NO;
        fprintf(stderr, "[dualmac] Compact HUD OFF\n");
        fflush(stderr);
    }
}

static void apply_cursor_lock_locked(bool lock) {
    bool currently_locked = atomic_load(&g_cursor_locked);
    if (lock == currently_locked) return;

    if (lock) {
        CGAssociateMouseAndMouseCursorPosition(false);
        CGDisplayHideCursor(CGMainDisplayID());
        atomic_store(&g_cursor_locked, true);
        fprintf(stderr, "[dualmac] Capture ON  ('0'=Release, 'G'=Car, 'O'=Aircraft, 'T'=Smart, ';'=Ping, 'H'=HUD)\n");
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);
        CGDisplayShowCursor(CGMainDisplayID());
        atomic_store(&g_cursor_locked, false);
        fprintf(stderr, "[dualmac] Capture OFF (cursor released)\n");
    }
    fflush(stderr);
}

static bool modifier_flag_is_down(int keycode, NSEventModifierFlags flags) {
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

static NSEvent *handle_local_nsevent(NSEvent *event) {
    if (!g_mapper || !event) return event;
    if (!atomic_load(&g_app_active)) return event;

    NSEventType type = [event type];
    NSEventModifierFlags flags = [event modifierFlags];

    /* Always allow Command shortcuts (Cmd+Q, Cmd+Tab, Cmd+H, Cmd+M) */
    if ((flags & NSEventModifierFlagCommand) != 0 &&
        (type == NSEventTypeKeyDown || type == NSEventTypeKeyUp)) {
        return event;
    }

    bool consume = false;
    bool toggle_hud_now = false;
    bool toggle_net_now = false;
    bool capture_changed = false;
    bool mode_changed = false;
    bool smart_changed = false;
    bool cruise_changed = false;
    bool sens_changed = false;
    bool mic_tapped = false;
    bool now_capture = false;
    int now_mode = 0;
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
            /* 'H' toggles HUD while captured; CapsLock(Ctrl)+H also works when capture is OFF */
            if (keycode == PSR_HUD_KEY_H && (g_mapper->capture_active || ctrl_held)) {
                if (!is_repeat) toggle_hud_now = true;
                consume = true;
                break;
            }
            /* ';' toggles live Ping/AWDL pill while captured; CapsLock+; works when capture is OFF */
            if (keycode == PSR_NET_KEY_SEMICOLON && (g_mapper->capture_active || ctrl_held)) {
                if (!is_repeat) toggle_net_now = true;
                consume = true;
                break;
            }
            consume = psr_mapper_handle_key(g_mapper, keycode, true);
            break;
        }
        case NSEventTypeKeyUp: {
            int keycode = (int)[event keyCode];
            if ((keycode == PSR_HUD_KEY_H || keycode == PSR_NET_KEY_SEMICOLON) && g_mapper->capture_active) {
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
    }
    if (now_mode != was_mode) {
        const char *mode_name = now_mode == 2 ? "AIRCRAFT" : (now_mode == 1 ? "VEHICLE" : "ON-FOOT");
        fprintf(stderr, "[dualmac] Mode (%s): %s\n", mode_was_auto ? "Smart-F" : "Manual", mode_name);
        fflush(stderr);
        mode_changed = true;
    }
    if (now_smart != was_smart) {
        fprintf(stderr, "[dualmac] Smart Mode: %s\n", now_smart ? "ON" : "OFF");
        fflush(stderr);
        smart_changed = true;
    }
    if (now_cruise != was_cruise && !capture_changed && !mode_changed && !smart_changed) {
        cruise_changed = true;
    }

    pthread_mutex_unlock(&g_lock);

    /* handle_local_nsevent always runs on main thread */
    if (!now_capture && g_assist_visible) {
        update_assist_pill_on_main(NO, nil, nil);
    }

    if (toggle_net_now) {
        set_net_visible_on_main(!atomic_load(&g_net_visible));
    }

    if (sens_changed) {
        persist_sensitivity_async(now_sens);
        NSString *msg = [NSString stringWithFormat:@"✦ TRACKPAD HASSASİYETİ: %.2fx (Kaydedildi)", now_sens];
        show_toast_on_main(msg, [NSColor colorWithRed:0.55 green:0.94 blue:1.0 alpha:1.0]);
    } else if (mic_tapped) {
        show_toast_on_main(@"● PS5 MİKROFON (MUTE TUŞU GÖNDERİLDİ)", [NSColor colorWithRed:1.0 green:0.74 blue:0.46 alpha:1.0]);
    } else if (toggle_hud_now) {
        set_hud_visible_on_main(!g_hud_visible, now_capture, now_mode, now_smart);
    } else if (capture_changed || mode_changed || smart_changed) {
        if (g_hud_visible) {
            if (g_hud_last_mode != now_mode ||
                g_hud_last_capture != (now_capture ? YES : NO) ||
                g_hud_last_smart != (now_smart ? YES : NO)) {
                rebuild_hud_content_on_main(now_capture, now_mode, now_smart);
            }
        } else if (smart_changed) {
            NSString *msg = now_smart
                ? @"✦ AKILLI MOD AÇIK · F:Oto-Araç · U/I/Y/L · 2P:Swipe"
                : @"○ AKILLI MOD KAPALI (Ham Kontrol · [T] Aç)";
            NSColor *col = now_smart
                ? [NSColor colorWithRed:0.65 green:0.95 blue:0.75 alpha:1.0]
                : [NSColor colorWithRed:0.86 green:0.86 blue:0.90 alpha:1.0];
            show_toast_on_main(msg, col);
        } else if (mode_changed) {
            NSString *msg;
            NSColor *col;
            if (now_mode == 2) {
                msg = @"✈ UÇAK MODU · W/S:Gaz · A/D:Roll · ↑↓/Shift-C:Pitch · Q/E:Dümen";
                col = [NSColor colorWithRed:0.78 green:0.64 blue:1.0 alpha:1.0];
            } else if (now_mode == 1) {
                msg = mode_was_auto
                    ? @"✦ OTO ARAÇ MODU · W:Gaz  S:Fren  F:İn · [U] Hotwire"
                    : @"ARAÇ MODU · W:Gaz  S:Fren  Space:El Freni · [H] Tuşlar";
                col = [NSColor colorWithRed:1.0 green:0.78 blue:0.38 alpha:1.0];
            } else {
                msg = mode_was_auto
                    ? @"✦ OTO YAYA MODU · WASD + Trackpad · [H] Tuşlar"
                    : @"YAYA MODU · WASD + Trackpad · [H] Tuşlar";
                col = [NSColor colorWithRed:0.48 green:0.88 blue:1.0 alpha:1.0];
            }
            show_toast_on_main(msg, col);
        } else if (capture_changed) {
            NSString *modeTag = now_mode == 2 ? @"UÇAK" : (now_mode == 1 ? @"ARAÇ" : @"YAYA");
            NSString *msg = now_capture
                ? [NSString stringWithFormat:@"● KİLİTLİ (%@) · [0] Bırak · [H] Tuşlar · [;] Ping", modeTag]
                : @"○ İMLEÇ SERBEST · [0] Tekrar Kilitle";
            NSColor *col = now_capture
                ? [NSColor colorWithRed:0.45 green:0.96 blue:0.64 alpha:1.0]
                : [NSColor colorWithRed:0.88 green:0.88 blue:0.90 alpha:1.0];
            show_toast_on_main(msg, col);
        }
    } else if (cruise_changed) {
        NSString *msg;
        if (now_cruise) {
            msg = now_mode == 2
                ? @"● OTO-UÇUŞ SEYRİ AÇIK (W/S/Space: İptal)"
                : (now_mode == 1 ? @"● HIZ SABİTLEYİCİ AÇIK (W/S/Space: İptal)" : @"● OTOMATİK KOŞMA AÇIK (W/S/Space: İptal)");
        } else {
            msg = @"○ SEYİR / OTO-KOŞ İPTAL";
        }
        NSColor *col = now_cruise
            ? [NSColor colorWithRed:0.50 green:0.92 blue:1.0 alpha:1.0]
            : [NSColor colorWithRed:0.85 green:0.85 blue:0.88 alpha:1.0];
        show_toast_on_main(msg, col);
    }

    return consume ? nil : event;
}

static void install_cocoa_monitors_on_main(void) {
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
            set_hud_visible_on_main(NO, false, 0, true);
            update_assist_pill_on_main(NO, nil, nil);
            set_net_visible_on_main(NO);
            if (g_toast_panel != nil) {
                ++g_toast_gen;
                [g_toast_panel orderOut:nil];
            }
        }];

        g_become_observer = [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                                            object:nil
                                             queue:nil
                                        usingBlock:^(NSNotification *note) {
            (void)note;
            atomic_store(&g_app_active, true);
        }];

        fprintf(stderr, "[dualmac] Ready (GTA 6 Smart Pack)! '0'=Toggle, 'G'=Car, 'O'=Aircraft, 'T'=Smart, ';'=Ping, 'H'=HUD.\n");
        fflush(stderr);
    }
}

static void cleanup_atexit(void) {
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
            ++g_toast_gen;
            if (g_toast_panel != nil) {
                [g_toast_panel orderOut:nil];
                g_toast_panel = nil;
                g_toast_label = nil;
            }
            if (g_assist_panel != nil) {
                [g_assist_panel orderOut:nil];
                g_assist_panel = nil;
                g_assist_label = nil;
                g_assist_visible = NO;
            }
            if (g_net_panel != nil) {
                [g_net_panel orderOut:nil];
                g_net_panel = nil;
                g_net_label = nil;
            }
            if (g_hud_panel != nil) {
                [g_hud_panel orderOut:nil];
                g_hud_panel = nil;
                g_hud_bg_view = nil;
                g_hud_visible = NO;
            }
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
        }
    };

    if ([NSThread isMainThread]) {
        teardown();
    } else {
        dispatch_async(dispatch_get_main_queue(), teardown);
    }
}

void psr_capture_sample_state(float dt_ms, PsrPadState *out_state) {
    int assist_kind = 0; /* 0=none, 1=hotwire, 2=circle, 3=sticky, 4=rapid */
    float srx = 0.0f;
    float sry = 0.0f;

    pthread_mutex_lock(&g_lock);
    if (g_mapper) {
        psr_mapper_tick(g_mapper, dt_ms);
        *out_state = g_mapper->pad;
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

    /* Update live top-center assist pill only on state transitions or <=25Hz while holding Y */
    uint64_t now = cap_now_ns();
    bool state_changed = (assist_kind != g_prev_assist_kind);
    bool throttle_ok = (now - g_last_assist_ui_ns) >= 40000000ULL; /* 40ms (~25Hz) */

    if (state_changed || (assist_kind == 3 && throttle_ok)) {
        g_prev_assist_kind = assist_kind;
        g_last_assist_ui_ns = now;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (assist_kind == 1) {
                update_assist_pill_on_main(
                    YES,
                    @"● HOTWIRE (R) ◡ OTOMATİK TARAMA",
                    [NSColor colorWithRed:1.0 green:0.82 blue:0.35 alpha:1.0]
                );
            } else if (assist_kind == 2) {
                update_assist_pill_on_main(
                    YES,
                    @"● TAM DAİRE (R) ↻ 360° DÖNDÜRME",
                    [NSColor colorWithRed:1.0 green:0.76 blue:0.42 alpha:1.0]
                );
            } else if (assist_kind == 3) {
                NSString *glyph = stick_direction_glyph(srx, sry);
                int px = (int)lroundf(srx * 100.0f);
                int py = (int)lroundf(sry * 100.0f);
                NSString *txt = [NSString stringWithFormat:@"● SAĞ ANALOG %@ (%+d%%, %+d%%) · Bırak: Sıfırla", glyph, px, py];
                update_assist_pill_on_main(
                    YES,
                    txt,
                    [NSColor colorWithRed:0.48 green:0.92 blue:1.0 alpha:1.0]
                );
            } else if (assist_kind == 4) {
                update_assist_pill_on_main(
                    YES,
                    @"● HIZLI ✕ (QTE / BİSİKLET / YÜZME)",
                    [NSColor colorWithRed:0.46 green:0.96 blue:0.64 alpha:1.0]
                );
            } else {
                update_assist_pill_on_main(NO, nil, nil);
            }
        });
    }
}

void psr_capture_on_dualsense_feedback(const PsrDualSenseFeedback *fb) {
    if (!fb || !atomic_load(&g_running) || !atomic_load(&g_app_active)) return;

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
                apply_lightbar_border_on_main(r, g, b);
            });
        }
    }
}
