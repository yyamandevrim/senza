/* In-game overlay HUD for the Senza capture bridge. All functions must be called on the main thread
 * unless noted otherwise.
 *
 * Copy passed to the HUD may use a tiny markup:
 *   {W}            Mac key rendered as a keycap          ({Space}, {⌫}, {1}–{4})
 *   <x> <o> <s> <t> PS face buttons as vector glyphs      (cross, circle, square, triangle)
 *   <R2> <L1> ...  any other PS control as an outlined chip
 */
#ifndef SENZA_HUD_H
#define SENZA_HUD_H

#import <Cocoa/Cocoa.h>
#include <stdbool.h>
#include <stdint.h>

typedef enum {
    SZ_TONE_NEUTRAL = 0,
    SZ_TONE_GOOD = 1,
    SZ_TONE_WARN = 2,
    SZ_TONE_BAD = 3,
} SzTone;

typedef enum {
    SZ_ASSIST_NONE = 0,
    SZ_ASSIST_HOTWIRE = 1,
    SZ_ASSIST_CIRCLE = 2,
    SZ_ASSIST_STICKY = 3,
    SZ_ASSIST_RAPID = 4,
} SzAssist;

typedef struct {
    bool capture;   /* trackpad + keys captured (cursor locked) */
    int mode;       /* 0 on foot, 1 vehicle, 2 aircraft */
    bool aiming;    /* L2 held on foot */
    bool smart;     /* smart assists enabled */
} SzHudState;

/* Short status message, top centre, fades after ~1.6 s. Suppressed while the panel or an assist is up. */
void hud_toast(SzTone tone, NSString *title, NSString *detail);

/* Persistent assist indicator while U / I / Y / L is held. kind SZ_ASSIST_NONE hides it. */
void hud_assist(SzAssist kind, float stick_x, float stick_y);
bool hud_assist_visible(void);

/* Top-right controls panel ('H'). */
void hud_panel_set_visible(bool visible, SzHudState st);
bool hud_panel_visible(void);
void hud_panel_refresh(SzHudState st); /* rebuilds only when something it shows changed */

/* Bottom PS -> keyboard prompt bar ('\'). */
void hud_prompt_refresh(SzHudState st);
bool hud_prompt_toggle(SzHudState st); /* returns the new enabled state */

/* Top-left network pill (';'). hud_net_visible() is safe from any thread. */
void hud_net_set_visible(bool visible);
bool hud_net_visible(void);
void hud_net_update(double avg_ms, double jitter_ms, double loss_pct, bool awdl_up, bool reachable);

/* Mirror the PS5 lightbar colour onto the panel edge (e.g. police flash). */
void hud_lightbar(uint8_t r, uint8_t g, uint8_t b);

/* Hide everything transient (app lost focus). */
void hud_hide_all(void);
/* Release every panel (capture stopped). */
void hud_teardown(void);

/* Rich text from the markup above; exposed for the preview tool. */
NSAttributedString *hud_rich_text(NSString *markup, NSFont *font, NSColor *color);

#endif
