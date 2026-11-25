/* Render every in-game HUD state to PNG without Remote Play: `make hud-preview` -> build/hud-preview/<state>.png
 *
 * Loads the real runtime profile (profiles/gta6.json exported to runtime_profile.cfg when present), drives the
 * public hud_* API and renders the overlay panels' layers onto a 1440x900 backdrop.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#import "capture_internal.h"

static NSString *g_out_dir = nil;

static void render(NSString *name) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    const CGFloat W = 1440, H = 900;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(W * 2)
                                                                    pixelsHigh:(NSInteger)(H * 2) bitsPerSample:8
                                                               samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = NSMakeSize(W, H);
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGContextRef ctx = gc.CGContext;

    /* Backdrop: a muted dusk scene so contrast reads like it would over gameplay. */
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {0.36, 0.33, 0.37, 1.0, 0.16, 0.17, 0.21, 1.0};
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, H), CGPointMake(0, 0), 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    CGContextSetRGBFillColor(ctx, 0.85, 0.72, 0.55, 0.10);
    CGContextFillEllipseInRect(ctx, CGRectMake(860, 420, 520, 360));

    NSScreen *screen = [NSScreen mainScreen];
    NSRect sf = screen.frame;
    for (NSWindow *w in [NSApp windows]) {
        if (![w isKindOfClass:[PsrHudPanel class]] || !w.isVisible) continue;
        NSView *v = w.contentView;
        [v displayIfNeeded];
        NSRect f = w.frame;
        /* map from the real screen into the 1440x900 canvas (anchor to edges) */
        CGFloat x = f.origin.x - sf.origin.x;
        CGFloat y = f.origin.y - sf.origin.y;
        if (x > sf.size.width / 2) x = W - (sf.size.width - x);
        else if (fabs(NSMidX(f) - NSMidX(sf)) < 4) x = (W - f.size.width) / 2;
        if (y > sf.size.height / 2) y = H - (sf.size.height - y);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, x, y);
        [v.layer renderInContext:ctx];
        CGContextRestoreGState(ctx);
    }
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [g_out_dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    [png writeToFile:path atomically:YES];
    printf("%s\n", path.UTF8String);
}

static void reset(void) {
    hud_hide_all();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        g_out_dir = argc > 1 ? @(argv[1]) : @"build/hud-preview";
        [[NSFileManager defaultManager] createDirectoryAtPath:g_out_dir withIntermediateDirectories:YES attributes:nil error:nil];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        static PsrMapper mapper;
        PsrConfig cfg;
        const char *cfg_path = argc > 2 ? argv[2] : NULL;
        if (!(cfg_path && psr_config_load_file(cfg_path, &cfg))) psr_config_init_default(&cfg);
        psr_mapper_init(&mapper, &cfg);
        g_mapper = &mapper;
        atomic_store(&g_app_active, true);
        atomic_store(&g_running, false); /* keep the ping thread from starting real pings */

        SzHudState foot = {.capture = true, .mode = 0, .aiming = false, .smart = true};
        SzHudState aim = {.capture = true, .mode = 0, .aiming = true, .smart = true};
        SzHudState car = {.capture = true, .mode = 1, .aiming = false, .smart = true};
        SzHudState air = {.capture = true, .mode = 2, .aiming = false, .smart = true};

        hud_prompt_refresh(foot);
        hud_panel_set_visible(true, foot);
        render(@"01-on-foot-panel-and-prompt");
        reset();

        hud_prompt_refresh(aim);
        hud_net_set_visible(true);
        hud_net_update(23.4, 1.8, 0.0, false, true);
        render(@"02-aiming-prompt-and-ping");
        reset();

        hud_prompt_refresh(car);
        hud_panel_set_visible(true, car);
        hud_lightbar(220, 40, 40);
        render(@"03-vehicle-panel-police-lightbar");
        reset();

        hud_prompt_refresh(air);
        hud_panel_set_visible(true, air);
        render(@"04-aircraft-panel");
        reset();

        hud_prompt_refresh(foot);
        hud_toast(SZ_TONE_GOOD, @"Kontrol kilitlendi", @"Yaya   {0} bırak   {H} tuşlar");
        hud_net_set_visible(true);
        hud_net_update(61.0, 9.3, 1.0, true, true);
        render(@"05-toast-and-bad-ping");
        reset();

        hud_prompt_refresh(foot);
        hud_assist(SZ_ASSIST_STICKY, 0.42f, -0.65f);
        render(@"06-assist-sticky");
        reset();

        hud_toast(SZ_TONE_WARN, @"DualSense bağlantısı kesildi", @"{0} trackpad modu");
        render(@"07-toast-warn");
        reset();
    }
    return 0;
}
