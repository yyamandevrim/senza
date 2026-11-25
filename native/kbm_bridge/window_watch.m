#import "capture_internal.h"

/* Auto-front tracker for newly opened RemotePlay / chiaki-ng windows */
NSHashTable<NSWindow *> *g_seen_windows = nil;
id g_window_close_observer = nil;
dispatch_source_t g_window_watch_timer = nil;
BOOL g_applied_target_center = NO;

BOOL is_trackable_app_window(NSWindow *win) {
    if (win == nil) return NO;
    if ([win isKindOfClass:[NSPanel class]]) return NO;
    if (!win.isVisible) return NO;
    NSRect f = win.frame;
    if (f.size.width < 200.0 || f.size.height < 150.0) return NO;
    return YES;
}

void apply_senza_branding_on_main(void) {
    if (NSApp == nil) return;
    const char *icon_env = getenv("SENZA_ICON_PATH");
    if (icon_env && icon_env[0] != '\0') {
        NSString *path = [NSString stringWithUTF8String:icon_env];
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
        if (img != nil) {
            [NSApp setApplicationIconImage:img];
        }
    }
}

void position_window_at_target_center_if_needed(NSWindow *win) {
    if (g_applied_target_center || win == nil) return;
    if ((win.styleMask & NSWindowStyleMaskFullScreen) != 0) {
        g_applied_target_center = YES;
        return;
    }
    const char *center_env = getenv("SENZA_TARGET_CENTER");
    if (!center_env || center_env[0] == '\0') {
        g_applied_target_center = YES;
        return;
    }
    double cx = 0.0, cy = 0.0;
    if (sscanf(center_env, "%lf,%lf", &cx, &cy) == 2 && cx > 0.0 && cy > 0.0) {
        NSRect wf = win.frame;
        NSScreen *scr = win.screen ?: [NSScreen mainScreen];
        NSRect vf = scr ? scr.visibleFrame : NSMakeRect(0, 0, 1440, 900);
        CGFloat ox = (CGFloat)cx - wf.size.width * 0.5;
        CGFloat oy = (CGFloat)cy - wf.size.height * 0.5;
        if (ox < vf.origin.x) ox = vf.origin.x;
        if (oy < vf.origin.y) oy = vf.origin.y;
        if (ox + wf.size.width > NSMaxX(vf)) ox = NSMaxX(vf) - wf.size.width;
        if (oy + wf.size.height > NSMaxY(vf)) oy = NSMaxY(vf) - wf.size.height;
        [win setFrameOrigin:NSMakePoint(ox, oy)];
    }
    g_applied_target_center = YES;
}

void bring_window_to_front_on_main(NSWindow *win) {
    if (NSApp == nil) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[NSRunningApplication currentApplication]
        activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    if ([NSApp respondsToSelector:@selector(activate)]) {
        [(id)NSApp performSelector:@selector(activate)];
    }
    if (win != nil) {
        [win makeKeyAndOrderFront:nil];
        [win orderFrontRegardless];
    }
}

void check_new_windows_and_focus_on_main(void) {
    if (NSApp == nil) return;
    if (g_seen_windows == nil) {
        g_seen_windows = [NSHashTable weakObjectsHashTable];
    }
    NSWindow *newest = nil;
    for (NSWindow *win in [NSApp windows]) {
        if (!is_trackable_app_window(win)) continue;
        if (![g_seen_windows containsObject:win]) {
            [g_seen_windows addObject:win];
            newest = win;
        }
    }
    if (newest != nil) {
        position_window_at_target_center_if_needed(newest);
        bring_window_to_front_on_main(newest);
    }
}
