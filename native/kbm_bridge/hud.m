/* In-game overlay HUD: controls panel, toast, assist pill, network pill and PS -> keyboard prompt bar.
 *
 * Visual language (one system for every surface):
 *   - dark console-overlay glass, hairline edge, radius 12 (panel) / 10 (bars) / 8 (pills)
 *   - three text roles (primary / secondary / muted), SF Pro for words, SF Mono for keys and figures
 *   - colour only where it means something: the four PS face-button glyphs and a small status dot
 *   - Mac shortcuts always render as keycaps
 */
#import "capture_internal.h"
#import "hud.h"

@implementation PsrHudPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

/* ==================== Tokens ==================== */

static const CGFloat kInset = 16.0;      /* distance from the visible screen edge */
static const CGFloat kRadiusPanel = 12.0;
static const CGFloat kRadiusBar = 10.0;
static const CGFloat kRadiusPill = 8.0;
static const CGFloat kBarHeight = 36.0;
static const CGFloat kPillHeight = 28.0;
static const CGFloat kRowHeight = 24.0;
static const CGFloat kPanelWidth = 360.0;
static const CGFloat kPanelPad = 16.0;
static const CGFloat kKeyColumn = 124.0;
static const CGFloat kFieldSlack = 6.0;   /* NSTextField's own horizontal inset */

static NSColor *c_text1(void) { return [NSColor colorWithWhite:0.94 alpha:1.0]; }
static NSColor *c_text2(void) { return [NSColor colorWithWhite:0.94 alpha:0.62]; }
static NSColor *c_text3(void) { return [NSColor colorWithWhite:0.94 alpha:0.40]; }
static NSColor *c_hairline(void) { return [NSColor colorWithWhite:1.0 alpha:0.10]; }
static NSColor *c_surface(void) { return [NSColor colorWithRed:0.067 green:0.071 blue:0.082 alpha:0.78]; }

static NSColor *c_tone(SzTone tone) {
    switch (tone) {
        case SZ_TONE_GOOD: return [NSColor colorWithRed:0.42 green:0.82 blue:0.56 alpha:1.0];
        case SZ_TONE_WARN: return [NSColor colorWithRed:0.91 green:0.72 blue:0.38 alpha:1.0];
        case SZ_TONE_BAD: return [NSColor colorWithRed:0.91 green:0.46 blue:0.43 alpha:1.0];
        default: return [NSColor colorWithWhite:0.94 alpha:0.50];
    }
}

/* PlayStation face-button colours: the only saturated colour in the HUD. */
static NSColor *c_cross(void) { return [NSColor colorWithRed:0.49 green:0.65 blue:0.95 alpha:1.0]; }
static NSColor *c_circle(void) { return [NSColor colorWithRed:0.93 green:0.44 blue:0.45 alpha:1.0]; }
static NSColor *c_square(void) { return [NSColor colorWithRed:0.86 green:0.57 blue:0.86 alpha:1.0]; }
static NSColor *c_triangle(void) { return [NSColor colorWithRed:0.30 green:0.80 blue:0.66 alpha:1.0]; }

static NSFont *f_text(CGFloat size, NSFontWeight w) { return [NSFont systemFontOfSize:size weight:w]; }
static NSFont *f_mono(CGFloat size, NSFontWeight w) { return [NSFont monospacedSystemFontOfSize:size weight:w]; }

/* ==================== Glyphs & keycaps ==================== */

static NSCache<NSString *, NSImage *> *g_glyph_cache = nil;

static NSImage *cached_image(NSString *key, NSImage * (^make)(void)) {
    if (g_glyph_cache == nil) g_glyph_cache = [[NSCache alloc] init];
    NSImage *img = [g_glyph_cache objectForKey:key];
    if (img == nil) {
        img = make();
        [g_glyph_cache setObject:img forKey:key];
    }
    return img;
}

static NSImage *face_glyph(char which) {
    NSString *key = [NSString stringWithFormat:@"face-%c", which];
    return cached_image(key, ^NSImage * {
        const CGFloat s = 13.0;
        return [NSImage imageWithSize:NSMakeSize(s, s) flipped:NO drawingHandler:^BOOL(NSRect r) {
            NSRect box = NSInsetRect(r, 1.75, 1.75);
            NSBezierPath *p = [NSBezierPath bezierPath];
            NSColor *col = c_cross();
            switch (which) {
                case 'o':
                    col = c_circle();
                    [p appendBezierPathWithOvalInRect:box];
                    break;
                case 's':
                    col = c_square();
                    [p appendBezierPathWithRect:NSInsetRect(box, 0.5, 0.5)];
                    break;
                case 't': {
                    col = c_triangle();
                    CGFloat h = NSWidth(box) * 0.88;
                    CGFloat y0 = NSMidY(box) - h * 0.45;
                    [p moveToPoint:NSMakePoint(NSMinX(box), y0)];
                    [p lineToPoint:NSMakePoint(NSMaxX(box), y0)];
                    [p lineToPoint:NSMakePoint(NSMidX(box), y0 + h)];
                    [p closePath];
                    break;
                }
                default:
                    [p moveToPoint:NSMakePoint(NSMinX(box), NSMinY(box))];
                    [p lineToPoint:NSMakePoint(NSMaxX(box), NSMaxY(box))];
                    [p moveToPoint:NSMakePoint(NSMinX(box), NSMaxY(box))];
                    [p lineToPoint:NSMakePoint(NSMaxX(box), NSMinY(box))];
                    break;
            }
            p.lineWidth = 1.6;
            p.lineJoinStyle = NSLineJoinStyleRound;
            p.lineCapStyle = NSLineCapStyleRound;
            [col setStroke];
            [p stroke];
            return YES;
        }];
    });
}

/* Mac keycap: raised key with a hairline edge and a darker bottom lip. */
static NSImage *keycap(NSString *label) {
    NSString *key = [@"key-" stringByAppendingString:label];
    return cached_image(key, ^NSImage * {
        NSDictionary *attrs = @{NSFontAttributeName: f_mono(10.5, NSFontWeightMedium),
                                NSForegroundColorAttributeName: c_text1()};
        NSSize ts = [label sizeWithAttributes:attrs];
        CGFloat h = 18.0;
        CGFloat w = MAX(h, ceil(ts.width) + 10.0);
        return [NSImage imageWithSize:NSMakeSize(w, h) flipped:NO drawingHandler:^BOOL(NSRect r) {
            NSRect lip = NSInsetRect(r, 0.5, 0.5);
            NSBezierPath *base = [NSBezierPath bezierPathWithRoundedRect:lip xRadius:4 yRadius:4];
            [[NSColor colorWithWhite:0.0 alpha:0.35] setFill];
            [base fill];
            NSRect top = NSMakeRect(NSMinX(lip), NSMinY(lip) + 1.5, NSWidth(lip), NSHeight(lip) - 1.5);
            NSBezierPath *cap = [NSBezierPath bezierPathWithRoundedRect:top xRadius:4 yRadius:4];
            [[NSColor colorWithWhite:1.0 alpha:0.12] setFill];
            [cap fill];
            [[NSColor colorWithWhite:1.0 alpha:0.16] setStroke];
            cap.lineWidth = 0.75;
            [cap stroke];
            NSPoint pt = NSMakePoint(NSMidX(top) - ts.width / 2.0, NSMidY(top) - ts.height / 2.0 + 0.5);
            [label drawAtPoint:pt withAttributes:attrs];
            return YES;
        }];
    });
}

/* Outlined chip for non-face PS controls (L1, R2, Options...). */
static NSImage *ps_chip(NSString *label) {
    NSString *key = [@"chip-" stringByAppendingString:label];
    return cached_image(key, ^NSImage * {
        NSDictionary *attrs = @{NSFontAttributeName: f_text(9.5, NSFontWeightSemibold),
                                NSForegroundColorAttributeName: c_text2()};
        NSSize ts = [label sizeWithAttributes:attrs];
        CGFloat h = 16.0;
        CGFloat w = ceil(ts.width) + 10.0;
        return [NSImage imageWithSize:NSMakeSize(w, h) flipped:NO drawingHandler:^BOOL(NSRect r) {
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:4 yRadius:4];
            [[NSColor colorWithWhite:1.0 alpha:0.28] setStroke];
            p.lineWidth = 1.0;
            [p stroke];
            [label drawAtPoint:NSMakePoint(NSMidX(r) - ts.width / 2.0, NSMidY(r) - ts.height / 2.0) withAttributes:attrs];
            return YES;
        }];
    });
}

static void append_image(NSMutableAttributedString *out, NSImage *img, NSFont *font) {
    NSTextAttachment *att = [[NSTextAttachment alloc] init];
    att.image = img;
    CGFloat y = round((font.capHeight - img.size.height) / 2.0);
    att.bounds = NSMakeRect(0, y, img.size.width, img.size.height);
    [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
}

NSAttributedString *hud_rich_text(NSString *markup, NSFont *font, NSColor *color) {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color};
    NSScanner *sc = [NSScanner scannerWithString:markup ?: @""];
    sc.charactersToBeSkipped = nil;
    NSCharacterSet *open = [NSCharacterSet characterSetWithCharactersInString:@"{<"];
    while (!sc.isAtEnd) {
        NSString *plain = nil;
        if ([sc scanUpToCharactersFromSet:open intoString:&plain] && plain.length) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:plain attributes:attrs]];
        }
        if (sc.isAtEnd) break;
        unichar opener = [markup characterAtIndex:sc.scanLocation];
        NSString *closer = opener == '{' ? @"}" : @">";
        NSUInteger start = sc.scanLocation;
        sc.scanLocation = start + 1;
        NSString *token = nil;
        if (![sc scanUpToString:closer intoString:&token] || sc.isAtEnd) {
            /* unbalanced: keep the literal text */
            [out appendAttributedString:[[NSAttributedString alloc]
                initWithString:[markup substringFromIndex:start] attributes:attrs]];
            break;
        }
        sc.scanLocation += 1;
        if (opener == '{') {
            append_image(out, keycap(token), font);
        } else if (token.length == 1 && strchr("xost", (char)[token characterAtIndex:0])) {
            append_image(out, face_glyph((char)[token characterAtIndex:0]), font);
        } else {
            append_image(out, ps_chip(token), font);
        }
    }
    return out;
}

/* ==================== Surfaces ==================== */

static NSTextField *make_text(NSAttributedString *s) {
    NSTextField *tf = [NSTextField labelWithAttributedString:s];
    tf.allowsEditingTextAttributes = YES; /* required for image attachments to draw */
    tf.selectable = NO;
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    tf.drawsBackground = NO;
    return tf;
}

static NSView *make_surface(NSRect frame, CGFloat radius) {
    NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:frame];
    v.material = NSVisualEffectMaterialHUDWindow;
    v.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    v.state = NSVisualEffectStateActive;
    v.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    v.wantsLayer = YES;
    v.layer.cornerRadius = radius;
    v.layer.masksToBounds = YES;
    v.layer.backgroundColor = c_surface().CGColor;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = c_hairline().CGColor;
    return v;
}

static NSView *make_dot(SzTone tone) {
    NSView *d = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 6, 6)];
    d.wantsLayer = YES;
    d.layer.cornerRadius = 3.0;
    d.layer.backgroundColor = c_tone(tone).CGColor;
    return d;
}

PsrHudPanel *create_overlay_panel(NSRect rect) {
    PsrHudPanel *panel = [[PsrHudPanel alloc] initWithContentRect:rect
                                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.hidesOnDeactivate = NO;
    panel.level = NSScreenSaverWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorTransient |
                               NSWindowCollectionBehaviorIgnoresCycle;
    return panel;
}

NSScreen *active_screen_on_main(void) {
    return [NSApp keyWindow].screen ?: [NSScreen mainScreen];
}

typedef enum { ANCHOR_TOP_CENTER, ANCHOR_TOP_LEFT, ANCHOR_TOP_RIGHT, ANCHOR_BOTTOM_CENTER } Anchor;

static void place_panel(NSPanel *panel, NSSize size, Anchor anchor) {
    NSScreen *screen = active_screen_on_main();
    NSRect sf = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    CGFloat x = NSMidX(sf) - size.width / 2.0;
    CGFloat y = NSMaxY(sf) - size.height - kInset;
    if (anchor == ANCHOR_TOP_LEFT) x = NSMinX(sf) + kInset;
    if (anchor == ANCHOR_TOP_RIGHT) x = NSMaxX(sf) - size.width - kInset;
    if (anchor == ANCHOR_BOTTOM_CENTER) y = NSMinY(sf) + kInset;
    [panel setFrame:NSMakeRect(round(x), round(y), size.width, size.height) display:YES];
}

/* A bar = surface + optional status dot + one line of rich text, sized to its content. */
static NSSize fill_bar(NSPanel *panel, NSAttributedString *text, SzTone tone, bool dot, CGFloat height,
                       CGFloat radius, CGFloat max_w) {
    const CGFloat pad = 14.0, dot_gap = 10.0;
    NSSize ts = [text size];
    CGFloat lead = dot ? 6.0 + dot_gap : 0.0;
    CGFloat w = MIN(max_w, ceil(ts.width) + kFieldSlack + lead + pad * 2.0);
    NSView *bg = make_surface(NSMakeRect(0, 0, w, height), radius);
    if (dot) {
        NSView *d = make_dot(tone);
        [d setFrameOrigin:NSMakePoint(pad, round((height - 6.0) / 2.0))];
        [bg addSubview:d];
    }
    NSTextField *tf = make_text(text);
    CGFloat th = ceil(ts.height);
    tf.frame = NSMakeRect(pad + lead, round((height - th) / 2.0), w - pad * 2.0 - lead, th);
    [bg addSubview:tf];
    panel.contentView = bg;
    return NSMakeSize(w, height);
}

static CGFloat screen_width(void) {
    NSScreen *s = active_screen_on_main();
    return s ? NSWidth(s.visibleFrame) : 1440.0;
}

/* ==================== Toast ==================== */

static PsrHudPanel *g_toast_panel = nil;
static uint64_t g_toast_gen = 0;

static PsrHudPanel *g_assist_panel = nil;
static bool g_assist_shown = false;

static PsrHudPanel *g_hud_panel = nil;
static NSView *g_hud_bg_view = nil;
static bool g_hud_shown = false;
static SzHudState g_hud_last;
static int g_hud_last_source = -1;
static uint8_t g_led[3] = {0, 0, 0};
static bool g_led_set = false;

static void hide_toast(void) {
    ++g_toast_gen;
    if (g_toast_panel) [g_toast_panel orderOut:nil];
}

static NSAttributedString *title_detail(NSString *title, NSString *detail) {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    [s appendAttributedString:hud_rich_text(title, f_text(12.5, NSFontWeightMedium), c_text1())];
    if (detail.length) {
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"   "
                                                                  attributes:@{NSFontAttributeName: f_text(12, NSFontWeightRegular)}]];
        [s appendAttributedString:hud_rich_text(detail, f_text(12, NSFontWeightRegular), c_text2())];
    }
    return s;
}

void hud_toast(SzTone tone, NSString *title, NSString *detail) {
    if (g_hud_shown || g_assist_shown) return;
    if (g_toast_panel == nil) g_toast_panel = create_overlay_panel(NSMakeRect(0, 0, 200, kBarHeight));
    NSSize sz = fill_bar(g_toast_panel, title_detail(title, detail), tone, true, kBarHeight, kRadiusBar,
                         screen_width() - kInset * 4);
    place_panel(g_toast_panel, sz, ANCHOR_TOP_CENTER);
    g_toast_panel.alphaValue = 1.0;
    [g_toast_panel orderFrontRegardless];

    uint64_t gen = ++g_toast_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_toast_gen != gen || g_toast_panel == nil) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.2;
            g_toast_panel.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (g_toast_gen == gen && g_toast_panel != nil) [g_toast_panel orderOut:nil];
        }];
    });
}

/* ==================== Assist pill ==================== */

static NSString *stick_arrow(float x, float y) {
    if (hypotf(x, y) < 0.12f) return @"·";
    static NSString *const arrows[8] = {@"→", @"↘", @"↓", @"↙", @"←", @"↖", @"↑", @"↗"};
    float a = atan2f(y, x); /* 0 right, +pi/2 down */
    int idx = (int)lroundf(a / (float)(M_PI / 4.0));
    idx = ((idx % 8) + 8) % 8;
    return arrows[idx];
}

bool hud_assist_visible(void) { return g_assist_shown; }

void hud_assist(SzAssist kind, float sx, float sy) {
    if (kind == SZ_ASSIST_NONE) {
        if (g_assist_panel && g_assist_shown) [g_assist_panel orderOut:nil];
        g_assist_shown = false;
        return;
    }
    hide_toast();
    NSString *title = nil, *detail = nil;
    switch (kind) {
        case SZ_ASSIST_HOTWIRE:
            title = @"Kontak yardımı";
            detail = @"Sağ çubuk yarım daire tarıyor";
            break;
        case SZ_ASSIST_CIRCLE:
            title = @"Tam tur";
            detail = @"Sağ çubuk 360° dönüyor";
            break;
        case SZ_ASSIST_STICKY:
            title = [NSString stringWithFormat:@"Sağ çubuk sabit  %@", stick_arrow(sx, sy)];
            detail = [NSString stringWithFormat:@"%+4d  %+4d   bırakınca sıfırlanır",
                      (int)lroundf(sx * 100.0f), (int)lroundf(-sy * 100.0f)];
            break;
        default:
            title = @"Hızlı <x>";
            detail = @"saniyede 12 basış";
            break;
    }
    if (g_assist_panel == nil) g_assist_panel = create_overlay_panel(NSMakeRect(0, 0, 200, kBarHeight));
    NSSize sz = fill_bar(g_assist_panel, title_detail(title, detail), SZ_TONE_GOOD, true, kBarHeight, kRadiusBar,
                         screen_width() - kInset * 4);
    if (!g_assist_shown || kind != SZ_ASSIST_STICKY) {
        place_panel(g_assist_panel, sz, ANCHOR_TOP_CENTER);
    } else {
        NSRect f = g_assist_panel.frame; /* keep it still while the readout updates */
        place_panel(g_assist_panel, NSMakeSize(MAX(sz.width, NSWidth(f)), sz.height), ANCHOR_TOP_CENTER);
    }
    if (!g_assist_shown) [g_assist_panel orderFrontRegardless];
    g_assist_shown = true;
}

/* ==================== Network pill ==================== */

static PsrHudPanel *g_net_panel = nil;
atomic_bool g_net_visible = false;
atomic_bool g_net_thread_active = false;

bool hud_net_visible(void) { return atomic_load(&g_net_visible); }

static void net_render(NSString *figures, SzTone tone) {
    NSAttributedString *s = [[NSAttributedString alloc]
        initWithString:figures
            attributes:@{NSFontAttributeName: f_mono(11, NSFontWeightMedium), NSForegroundColorAttributeName: c_text1()}];
    NSSize sz = fill_bar(g_net_panel, s, tone, true, kPillHeight, kRadiusPill, 480);
    place_panel(g_net_panel, sz, ANCHOR_TOP_LEFT);
}

void hud_net_update(double avg_ms, double jitter_ms, double loss_pct, bool awdl_up, bool reachable) {
    if (!atomic_load(&g_net_visible) || g_net_panel == nil) return;
    NSString *awdl = awdl_up ? @"AWDL açık" : @"AWDL kapalı";
    if (!reachable) {
        net_render([NSString stringWithFormat:@"Yanıt yok   %@", awdl], SZ_TONE_BAD);
        return;
    }
    SzTone tone = SZ_TONE_GOOD;
    if (loss_pct > 0.5 || avg_ms >= 75.0 || awdl_up) tone = SZ_TONE_BAD;
    else if (avg_ms >= 35.0 || jitter_ms >= 8.0) tone = SZ_TONE_WARN;
    net_render([NSString stringWithFormat:@"%3.0f ms   ±%.1f   %.0f%% kayıp   %@", avg_ms, jitter_ms, loss_pct, awdl],
               tone);
}

void hud_net_set_visible(bool visible) {
    if (!visible) {
        atomic_store(&g_net_visible, false);
        if (g_net_panel) [g_net_panel orderOut:nil];
        return;
    }
    if (g_net_panel == nil) g_net_panel = create_overlay_panel(NSMakeRect(0, 0, 200, kPillHeight));
    atomic_store(&g_net_visible, true);
    net_render(@"Ölçülüyor", SZ_TONE_NEUTRAL);
    [g_net_panel orderFrontRegardless];
    net_telemetry_start();
}

/* ==================== Key labels ==================== */

static NSString *keycode_label(int code) {
    switch (code) {
        case PSR_KEY_LMB: return @"Tık";
        case PSR_KEY_RMB: return @"Sağ tık";
        case PSR_KEY_MMB: return @"Orta tık";
        case PSR_KEY_MOUSE4: return @"M4";
        case PSR_KEY_MOUSE5: return @"M5";
        case 0: return @"A"; case 1: return @"S"; case 2: return @"D"; case 3: return @"F";
        case 4: return @"H"; case 5: return @"G"; case 6: return @"Z"; case 7: return @"X";
        case 8: return @"C"; case 9: return @"V"; case 11: return @"B"; case 12: return @"Q";
        case 13: return @"W"; case 14: return @"E"; case 15: return @"R"; case 16: return @"Y";
        case 17: return @"T"; case 18: return @"1"; case 19: return @"2"; case 20: return @"3";
        case 21: return @"4"; case 22: return @"6"; case 23: return @"5"; case 24: return @"=";
        case 25: return @"9"; case 26: return @"7"; case 27: return @"-"; case 28: return @"8";
        case 29: return @"0"; case 30: return @"]"; case 31: return @"O"; case 32: return @"U";
        case 33: return @"["; case 34: return @"I"; case 35: return @"P"; case 36: return @"⏎";
        case 37: return @"L"; case 38: return @"J"; case 40: return @"K"; case 41: return @";";
        case 42: return @"\\"; case 45: return @"N"; case 46: return @"M"; case 48: return @"Tab";
        case 49: return @"Space"; case 50: return @"`"; case 51: return @"⌫"; case 53: return @"Esc";
        case 56: case 60: return @"Shift";
        case 57: return @"Caps";
        case 58: case 61: return @"Opt";
        case 59: case 62: return @"Ctrl";
        case 123: return @"←"; case 124: return @"→"; case 125: return @"↓"; case 126: return @"↑";
        default: return @"?";
    }
}

/* Primary ergonomic MacBook keys win over secondary/fallback bindings for the same target. */
static int binding_priority(int code) {
    switch (code) {
        case 49: case 48: case 56: case 59: case PSR_KEY_LMB: case 13: case 1: case 12: case 14:
        case 15: case 3: case 8: case 11: case 46: case 18: case 19: case 20: case 21:
            return 3;
        case 36: case 51: case 123: case 124: case 125: case 126:
            return 1;
        default:
            return 2;
    }
}

static NSString *key_for(const PsrBinding *list, int count, PsrTarget target, NSString *fallback) {
    int best = -1, prio = -1;
    for (int i = 0; i < count; i++) {
        if (list[i].target != target) continue;
        int p = binding_priority(list[i].input_code);
        if (p > prio) {
            prio = p;
            best = list[i].input_code;
        }
    }
    return best >= 0 ? keycode_label(best) : fallback;
}

/* ==================== Prompt bar ==================== */

static PsrHudPanel *g_prompt_panel = nil;
static bool g_prompt_enabled = true;
static bool g_prompt_shown = false;

static NSString *mode_name(SzHudState st) {
    if (st.mode == 2) return @"Uçak";
    if (st.mode == 1) return @"Araç";
    return st.aiming ? @"Nişan" : @"Yaya";
}

/* Items are "<ps> {key} label" markup; joined with generous gaps, no separators. */
static NSArray<NSString *> *prompt_items(SzHudState st, const PsrConfig *c) {
    if (st.mode == 2) {
        const PsrBinding *b = c->aircraft;
        int n = c->aircraft_count;
        return @[
            [NSString stringWithFormat:@"<R2><L2> {%@}{%@} gaz", key_for(b, n, PSR_TRIGGER_R2, @"W"), key_for(b, n, PSR_TRIGGER_L2, @"S")],
            @"{↑}{↓}{←}{→} uçuş",
            [NSString stringWithFormat:@"<s> {%@} sol dümen", key_for(b, n, PSR_BTN_SQUARE, @"Q")],
            [NSString stringWithFormat:@"<o> {%@} sağ dümen", key_for(b, n, PSR_BTN_CIRCLE, @"E")],
            [NSString stringWithFormat:@"<R1> {%@} ateş", key_for(b, n, PSR_BTN_R1, @"Space")],
            [NSString stringWithFormat:@"<L1> {%@} silah", key_for(b, n, PSR_BTN_L1, @"Tab")],
            [NSString stringWithFormat:@"<L3> {%@} iniş takımı", key_for(b, n, PSR_BTN_L3, @"R")],
            [NSString stringWithFormat:@"<t> {%@} atla", key_for(b, n, PSR_BTN_TRIANGLE, @"F")],
            [NSString stringWithFormat:@"{%@} otomatik uçuş", keycode_label(c->cruise_toggle_key)],
        ];
    }
    if (st.mode == 1) {
        const PsrBinding *b = c->vehicle;
        int n = c->vehicle_count;
        return @[
            [NSString stringWithFormat:@"<R2><L2> {%@}{%@} gaz, fren", key_for(b, n, PSR_TRIGGER_R2, @"W"), key_for(b, n, PSR_TRIGGER_L2, @"S")],
            [NSString stringWithFormat:@"<x> {%@} el freni", key_for(b, n, PSR_BTN_CROSS, @"Space")],
            [NSString stringWithFormat:@"<R1> {%@} ateş", key_for(b, n, PSR_BTN_R1, @"Tık")],
            [NSString stringWithFormat:@"<o> {%@} far", key_for(b, n, PSR_BTN_CIRCLE, @"C")],
            [NSString stringWithFormat:@"<s> {%@} vur", key_for(b, n, PSR_BTN_SQUARE, @"R")],
            [NSString stringWithFormat:@"<L1> {%@} silah", key_for(b, n, PSR_BTN_L1, @"Tab")],
            [NSString stringWithFormat:@"<L3> {%@} korna", key_for(b, n, PSR_BTN_L3, @"Shift")],
            [NSString stringWithFormat:@"<t> {%@} in", key_for(b, n, PSR_BTN_TRIANGLE, @"F")],
            [NSString stringWithFormat:@"<R3> {%@} arkaya bak", key_for(b, n, PSR_BTN_R3, @"B")],
        ];
    }
    const PsrBinding *b = c->on_foot;
    int n = c->on_foot_count;
    if (st.aiming) {
        return @[
            [NSString stringWithFormat:@"<R2> {%@} ateş", key_for(b, n, PSR_TRIGGER_R2, @"Tık")],
            [NSString stringWithFormat:@"<R1> {%@} hızlı atış", key_for(b, n, PSR_BTN_R1, @"Q")],
            [NSString stringWithFormat:@"<t> {%@} silah değiştir", key_for(b, n, PSR_BTN_TRIANGLE, @"E")],
            [NSString stringWithFormat:@"<s> {%@} şarjör", key_for(b, n, PSR_BTN_SQUARE, @"R")],
            [NSString stringWithFormat:@"<R3> {%@} zoom", key_for(b, n, PSR_BTN_R3, @"B")],
            [NSString stringWithFormat:@"{%@} omuz değiştir", st.smart ? @"V" : key_for(b, n, PSR_BTN_DPAD_LEFT, @"4")],
            [NSString stringWithFormat:@"{%@} sniper", keycode_label(c->walk_mod_key)],
            [NSString stringWithFormat:@"<x> {%@} takla", key_for(b, n, PSR_BTN_CROSS, @"Space")],
        ];
    }
    NSString *enter = key_for(b, n, PSR_BTN_TRIANGLE, @"E");
    return @[
        [NSString stringWithFormat:@"<x> {%@} zıpla", key_for(b, n, PSR_BTN_CROSS, @"Space")],
        [NSString stringWithFormat:@"<o> {%@} eğil", key_for(b, n, PSR_BTN_CIRCLE, @"C")],
        [NSString stringWithFormat:@"<s> {%@} dövüş", key_for(b, n, PSR_BTN_SQUARE, @"R")],
        st.smart ? [NSString stringWithFormat:@"<t> {%@}{F} bin", enter] : [NSString stringWithFormat:@"<t> {%@} bin", enter],
        [NSString stringWithFormat:@"<L2> {%@} nişan", key_for(b, n, PSR_TRIGGER_L2, @"Ctrl")],
        [NSString stringWithFormat:@"<R2> {%@} ateş", key_for(b, n, PSR_TRIGGER_R2, @"Tık")],
        [NSString stringWithFormat:@"<L1> {%@} silah", key_for(b, n, PSR_BTN_L1, @"Tab")],
        [NSString stringWithFormat:@"<R1> {%@} siper", key_for(b, n, PSR_BTN_R1, @"Q")],
        [NSString stringWithFormat:@"<L3> {%@} koş", key_for(b, n, PSR_BTN_L3, @"Shift")],
        [NSString stringWithFormat:@"<Map> {%@} harita", key_for(b, n, PSR_BTN_TOUCHPAD, @"M")],
    ];
}

static bool phys_mode_active(void) {
    return atomic_load(&g_input_source) == 1 && atomic_load(&g_phys_connected);
}

void hud_prompt_refresh(SzHudState st) {
    bool show = st.capture && !phys_mode_active() && g_prompt_enabled && atomic_load(&g_app_active);
    if (!show) {
        if (g_prompt_panel && g_prompt_shown) [g_prompt_panel orderOut:nil];
        g_prompt_shown = false;
        return;
    }
    PsrConfig cfg;
    pthread_mutex_lock(&g_lock);
    bool has = g_mapper != NULL;
    if (has) cfg = g_mapper->cfg;
    pthread_mutex_unlock(&g_lock);
    if (!has) return;

    NSFont *font = f_text(12, NSFontWeightRegular);
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    [s appendAttributedString:[[NSAttributedString alloc]
        initWithString:mode_name(st)
            attributes:@{NSFontAttributeName: f_text(12, NSFontWeightMedium), NSForegroundColorAttributeName: c_text1()}]];
    NSAttributedString *gap = [[NSAttributedString alloc] initWithString:@"      " attributes:@{NSFontAttributeName: font}];
    for (NSString *item in prompt_items(st, &cfg)) {
        [s appendAttributedString:gap];
        [s appendAttributedString:hud_rich_text(item, font, c_text2())];
    }
    if (g_prompt_panel == nil) g_prompt_panel = create_overlay_panel(NSMakeRect(0, 0, 400, kBarHeight));
    NSSize sz = fill_bar(g_prompt_panel, s, SZ_TONE_NEUTRAL, false, kBarHeight, kRadiusBar, screen_width() - kInset * 2);
    place_panel(g_prompt_panel, sz, ANCHOR_BOTTOM_CENTER);
    if (!g_prompt_shown) [g_prompt_panel orderFrontRegardless];
    g_prompt_shown = true;
}

bool hud_prompt_toggle(SzHudState st) {
    g_prompt_enabled = !g_prompt_enabled;
    hud_prompt_refresh(st);
    return g_prompt_enabled;
}

/* ==================== Controls panel ==================== */

typedef struct {
    NSString *keys;
    NSString *what;
} Row;

#define ROW(k, w) ((Row){(k), (w)})

static NSArray<NSValue *> *rows_value(const Row *rows, size_t n) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (size_t i = 0; i < n; i++) [a addObject:[NSValue valueWithBytes:&rows[i] objCType:@encode(Row)]];
    return a;
}

static NSArray<NSValue *> *panel_rows(SzHudState st, bool phys) {
    if (phys) {
        const Row r[] = {
            ROW(@"{0}", @"Trackpad ve klavyeye geç"),
            ROW(@"{;}", @"Ping, jitter ve AWDL"),
            ROW(@"{[}", @"PS5 mikrofonunu sustur"),
            ROW(@"{H}", @"Bu paneli gizle"),
            ROW(@"Kol", @"Dokununca DualSense'e döner"),
        };
        return rows_value(r, sizeof(r) / sizeof(r[0]));
    }
    if (st.mode == 2) {
        const Row r[] = {
            ROW(@"{W} {S}", @"Gaz <R2>, alçal <L2>"),
            ROW(@"{↑}{↓}{←}{→}", @"Yunuslama ve yatış"),
            ROW(@"{A} {D}", st.smart ? @"Tek elle yatış, yumuşak" : @"Tek elle yatış"),
            ROW(@"{Q} {E}", @"Dümen <s> <o>"),
            ROW(@"{Space} {Tık}", @"Ateş <R1>"),
            ROW(@"{Tab} {Ctrl}", @"Silah <L1>"),
            ROW(@"{R} {F}", @"İniş takımı <L3>, atla <t>"),
            ROW(@"{]} {M} {B}", @"Otomatik uçuş, harita, arka <R3>"),
            ROW(@"{1}–{4}", @"Yön tuşları"),
            ROW(@"{-} {=}", @"Hassasiyet"),
        };
        return rows_value(r, sizeof(r) / sizeof(r[0]));
    }
    if (st.mode == 1) {
        const Row r[] = {
            ROW(@"{W} {S}", @"Gaz <R2>, fren <L2>"),
            ROW(@"{A} {D}", st.smart ? @"Yumuşak direksiyon" : @"Direksiyon"),
            ROW(@"{Space}", @"El freni <x>"),
            ROW(@"{Tık} {Q}", @"Araçtan ateş <R1>"),
            ROW(@"{Tab} {Ctrl}", st.smart ? @"Silah çarkı <L1>" : @"Silah <L1>"),
            ROW(@"{C} {R}", @"Far <o>, vur <s>"),
            ROW(@"{Shift} {E}", @"Korna, nitro <L3>"),
            ROW(@"{F}", st.smart ? @"İn <t>, yaya moduna döner" : @"İn <t>"),
            ROW(@"{B} {M}", @"Arka <R3>, harita"),
            ROW(@"{U} {I} {L}", @"Kontak, tam tur, hızlı <x>"),
            ROW(@"{]}", @"Sabit hız"),
        };
        return rows_value(r, sizeof(r) / sizeof(r[0]));
    }
    const Row r[] = {
        ROW(@"{W}{A}{S}{D}", @"Hareket, {Z} yürü"),
        ROW(@"Trackpad", @"Kamera, iki parmak touchpad"),
        ROW(@"{Tık} {J}", @"Ateş <R2>"),
        ROW(@"{Ctrl} {Sağ tık}", st.smart ? @"Nişan <L2>, {V} omuz, {Z} sniper" : @"Nişan <L2>"),
        ROW(@"{Shift} {]}", @"Koş <L3>, otomatik koşu"),
        ROW(@"{Space} {⏎}", @"Zıpla, tırman <x>"),
        ROW(@"{C} {⌫}", @"Eğil, geri <o>"),
        ROW(@"{R} {V}", @"Şarjör, dövüş <s>"),
        ROW(@"{E} {F}", st.smart ? @"Etkileşim <t>, {F} araca bin" : @"Etkileşim, bin <t>"),
        ROW(@"{Q} {Tab}", st.smart ? @"Siper <R1>, silah çarkı <L1>" : @"Siper <R1>, silah <L1>"),
        ROW(@"{U} {I} {Y} {L}", @"Kontak, tam tur, sağ çubuk, hızlı <x>"),
        ROW(@"{M} {Esc} {B}", @"Harita, duraklat, zoom <R3>"),
        ROW(@"{1}–{4}", @"Yön tuşları"),
    };
    return rows_value(r, sizeof(r) / sizeof(r[0]));
}

static void apply_led_edge(void) {
    if (!g_hud_shown || g_hud_bg_view == nil || !g_led_set) return;
    if ((int)g_led[0] + g_led[1] + g_led[2] < 24) {
        g_hud_bg_view.layer.borderColor = c_hairline().CGColor;
        return;
    }
    g_hud_bg_view.layer.borderColor =
        [NSColor colorWithRed:g_led[0] / 255.0 green:g_led[1] / 255.0 blue:g_led[2] / 255.0 alpha:0.55].CGColor;
}

static void rebuild_panel(SzHudState st) {
    bool phys = phys_mode_active();
    NSString *ctrlName = @"DualSense", *battery = nil;
    if (phys) {
        pthread_mutex_lock(&g_phys_lock);
        GCController *ctrl = g_phys_controller;
        if (ctrl.vendorName.length) ctrlName = ctrl.vendorName;
        if (ctrl.battery && ctrl.battery.batteryLevel >= 0.0f) {
            bool charging = ctrl.battery.batteryState == GCDeviceBatteryStateCharging;
            battery = [NSString stringWithFormat:@"%%%d%@", (int)lroundf(ctrl.battery.batteryLevel * 100.0f),
                                                 charging ? @" · şarjda" : @""];
        }
        pthread_mutex_unlock(&g_phys_lock);
    }

    NSArray<NSValue *> *rows = panel_rows(st, phys);
    const CGFloat headerH = 44.0, footerH = 36.0;
    CGFloat h = headerH + kPanelPad / 2 + (CGFloat)rows.count * kRowHeight + kPanelPad / 2 + footerH;
    NSView *bg = make_surface(NSMakeRect(0, 0, kPanelWidth, h), kRadiusPanel);

    /* Header: mode name + smart tag on the left, live state on the right. */
    NSString *title = phys ? ctrlName : (st.mode == 2 ? @"Uçak" : (st.mode == 1 ? @"Araç" : @"Yaya"));
    NSMutableAttributedString *ht = [[NSMutableAttributedString alloc]
        initWithString:title
            attributes:@{NSFontAttributeName: f_text(13.5, NSFontWeightSemibold), NSForegroundColorAttributeName: c_text1()}];
    NSString *tag = phys ? @"hibrit" : (st.smart ? @"akıllı mod" : @"ham kontrol");
    [ht appendAttributedString:[[NSAttributedString alloc]
        initWithString:[@"   " stringByAppendingString:tag]
            attributes:@{NSFontAttributeName: f_text(12, NSFontWeightRegular), NSForegroundColorAttributeName: c_text3()}]];
    NSTextField *titleTf = make_text(ht);
    titleTf.frame = NSMakeRect(kPanelPad, h - headerH + 13, 220, 18);
    [bg addSubview:titleTf];

    bool live = phys || st.capture;
    NSString *state = phys ? (battery ?: @"bağlı") : (st.capture ? @"kilitli" : @"serbest");
    NSAttributedString *stS = [[NSAttributedString alloc]
        initWithString:state
            attributes:@{NSFontAttributeName: f_text(12, NSFontWeightRegular), NSForegroundColorAttributeName: c_text2()}];
    NSTextField *stTf = make_text(stS);
    CGFloat stW = ceil([stS size].width) + kFieldSlack;
    stTf.frame = NSMakeRect(kPanelWidth - kPanelPad - stW, h - headerH + 13, stW, 18);
    [bg addSubview:stTf];
    NSView *dot = make_dot(live ? SZ_TONE_GOOD : SZ_TONE_WARN);
    [dot setFrameOrigin:NSMakePoint(NSMinX(stTf.frame) - 12, h - headerH + 19)];
    [bg addSubview:dot];

    NSView *rule = [[NSView alloc] initWithFrame:NSMakeRect(kPanelPad, h - headerH, kPanelWidth - kPanelPad * 2, 1)];
    rule.wantsLayer = YES;
    rule.layer.backgroundColor = c_hairline().CGColor;
    [bg addSubview:rule];

    NSFont *rowFont = f_text(12, NSFontWeightRegular);
    CGFloat y = h - headerH - kPanelPad / 2 - kRowHeight;
    for (NSValue *v in rows) {
        Row r;
        [v getValue:&r];
        NSTextField *k = make_text(hud_rich_text(r.keys, rowFont, c_text2()));
        k.frame = NSMakeRect(kPanelPad, y + 3, kKeyColumn - 8, 18);
        [bg addSubview:k];
        NSTextField *d = make_text(hud_rich_text(r.what, rowFont, c_text1()));
        d.frame = NSMakeRect(kPanelPad + kKeyColumn, y + 3, kPanelWidth - kPanelPad * 2 - kKeyColumn, 18);
        [bg addSubview:d];
        y -= kRowHeight;
    }

    NSView *rule2 = [[NSView alloc] initWithFrame:NSMakeRect(kPanelPad, footerH, kPanelWidth - kPanelPad * 2, 1)];
    rule2.wantsLayer = YES;
    rule2.layer.backgroundColor = c_hairline().CGColor;
    [bg addSubview:rule2];
    NSString *foot = phys ? @"{0} trackpad   {;} ping   {[} mikrofon   {H} gizle"
                          : @"{0} imleç   {G} araç   {O} uçak   {T} akıllı   {H} gizle";
    NSTextField *ft = make_text(hud_rich_text(foot, f_text(11.5, NSFontWeightRegular), c_text3()));
    ft.frame = NSMakeRect(kPanelPad, 9, kPanelWidth - kPanelPad * 2, 18);
    [bg addSubview:ft];

    if (g_hud_panel == nil) g_hud_panel = create_overlay_panel(NSMakeRect(0, 0, kPanelWidth, h));
    g_hud_panel.contentView = bg;
    g_hud_bg_view = bg;
    place_panel(g_hud_panel, NSMakeSize(kPanelWidth, h), ANCHOR_TOP_RIGHT);
    g_hud_last = st;
    g_hud_last_source = phys ? 1 : 0;
    apply_led_edge();
}

bool hud_panel_visible(void) { return g_hud_shown; }

void hud_panel_set_visible(bool visible, SzHudState st) {
    if (visible) {
        hide_toast();
        g_hud_shown = true;
        rebuild_panel(st);
        [g_hud_panel orderFrontRegardless];
    } else if (g_hud_panel && g_hud_shown) {
        [g_hud_panel orderOut:nil];
        g_hud_shown = false;
    }
}

void hud_panel_refresh(SzHudState st) {
    if (!g_hud_shown) return;
    int src = phys_mode_active() ? 1 : 0;
    if (src != g_hud_last_source || st.mode != g_hud_last.mode || st.capture != g_hud_last.capture ||
        st.smart != g_hud_last.smart) {
        rebuild_panel(st);
    }
}

void hud_lightbar(uint8_t r, uint8_t g, uint8_t b) {
    g_led[0] = r;
    g_led[1] = g;
    g_led[2] = b;
    g_led_set = true;
    apply_led_edge();
}

/* ==================== Lifecycle ==================== */

void hud_hide_all(void) {
    hud_panel_set_visible(false, (SzHudState){0});
    if (g_prompt_panel && g_prompt_shown) [g_prompt_panel orderOut:nil];
    g_prompt_shown = false;
    hud_assist(SZ_ASSIST_NONE, 0, 0);
    hud_net_set_visible(false);
    hide_toast();
}

void hud_teardown(void) {
    hud_hide_all();
    g_toast_panel = nil;
    g_assist_panel = nil;
    g_net_panel = nil;
    g_prompt_panel = nil;
    g_hud_panel = nil;
    g_hud_bg_view = nil;
}
