/* Internal shared state & helpers for the Senza capture bridge (not a public API).
 *
 * Split of the former macos_capture.m monolith:
 *   macos_capture.m   NSEvent capture, cursor lock, mapper sampling, feedback, start/stop
 *   hud.m             overlay panels: HUD, toast, assist pill, ping pill, prompt bar
 *   net_telemetry.m   background ping / AWDL probe thread
 *   phys_controller.m physical DualSense hybrid hot-swap (GameController + CoreHaptics)
 *   window_watch.m    auto-front + centering of new Remote Play windows
 */
#ifndef SENZA_CAPTURE_INTERNAL_H
#define SENZA_CAPTURE_INTERNAL_H

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>

#include "config_loader.h"
#include "macos_capture.h"
#import "hud.h"

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
#include <sys/stat.h>
#include <unistd.h>

#define PSR_HUD_KEY_H 4           /* macOS virtual keycode for 'H' */
#define PSR_NET_KEY_SEMICOLON 41  /* macOS virtual keycode for ';' (live ping/AWDL overlay) */
#define PSR_PROMPT_KEY_BACKSLASH 42 /* macOS virtual keycode for '\' (live PS->Key prompt bar) */

@interface PsrHudPanel : NSPanel
@end

extern PsrMapper *g_mapper;
extern pthread_mutex_t g_lock;
extern atomic_bool g_running;
extern atomic_bool g_cursor_locked;
extern atomic_bool g_app_active;
extern id g_local_monitor;
extern id g_resign_observer;
extern id g_become_observer;
extern time_t g_cfg_last_mtime;
extern int g_cfg_watch_tick;
extern mach_timebase_info_data_t g_cap_timebase;
extern uint64_t g_last_haptic_ns;
extern uint64_t g_last_assist_ui_ns;
extern int g_prev_assist_kind;
extern atomic_bool g_net_visible;
extern atomic_bool g_net_thread_active;
extern bool g_prev_aiming_bar;
extern pthread_mutex_t g_phys_lock;
extern GCController *g_phys_controller;
extern CHHapticEngine *g_phys_haptic_left;
extern CHHapticEngine *g_phys_haptic_right;
extern id g_phys_connect_obs;
extern id g_phys_disconnect_obs;
extern atomic_bool g_phys_connected;
extern atomic_int g_input_source;
extern bool g_phys_touch_was_down;
extern uint8_t g_phys_touch_id;
extern uint64_t g_last_phys_rumble_ns;
extern float g_phys_mic_pulse_ms;
extern NSHashTable<NSWindow *> *g_seen_windows;
extern id g_window_close_observer;
extern dispatch_source_t g_window_watch_timer;
extern BOOL g_applied_target_center;

uint64_t cap_now_ns(void);
int current_mode_id(bool vehicle_mode, bool aircraft_mode);
void persist_sensitivity_async(float new_sens);
BOOL is_text_input_focused_on_main(void);
void check_profile_hot_reload_on_main(void);
void set_mouse_coalescing_safe(BOOL enabled);
void apply_cursor_lock_locked(bool lock);
bool modifier_flag_is_down(int keycode, NSEventModifierFlags flags);
NSEvent *handle_local_nsevent(NSEvent *event);
void install_cocoa_monitors_on_main(void);
void cleanup_atexit(void);
PsrHudPanel *create_overlay_panel(NSRect rect);
NSScreen *active_screen_on_main(void);
bool check_awdl_is_up(void);
void sanitize_ping_host(char *out, size_t out_sz);
void *net_telemetry_thread(void *arg);
int16_t phys_float_to_axis(float v);
int16_t phys_float_to_trigger(float v);
void stop_phys_haptics_locked(void);
void attach_phys_controller_locked(GCController *ctrl);
void refresh_phys_controllers_on_main(bool announce_toast);
bool sample_physical_dualsense(PsrPadState *out, bool *out_activity);
void play_haptic_pulse_on_engine(CHHapticEngine *engine, float intensity, float sharpness);
void forward_phys_rumble_on_main(uint8_t left_val, uint8_t right_val);
void forward_phys_lightbar_on_main(uint8_t r, uint8_t g, uint8_t b);
BOOL is_trackable_app_window(NSWindow *win);
void apply_senza_branding_on_main(void);
void position_window_at_target_center_if_needed(NSWindow *win);
void bring_window_to_front_on_main(NSWindow *win);
void check_new_windows_and_focus_on_main(void);

#endif
