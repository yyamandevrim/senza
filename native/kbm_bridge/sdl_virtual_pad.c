#include "config_loader.h"
#include "macos_capture.h"
#include "mapper_core.h"

#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Minimal SDL2 types so we compile without needing SDL2 headers installed */
typedef uint32_t Uint32;
typedef int16_t Sint16;
typedef uint8_t Uint8;
typedef struct _SDL_Joystick SDL_Joystick;
typedef union SDL_Event {
    Uint32 type;
    Uint8 padding[128];
} SDL_Event;

#define PSR_SDL_INIT_GAMECONTROLLER 0x00002000u
#define PSR_SDL_JOYSTICK_TYPE_GAMECONTROLLER 1
#define PSR_SDL_AXIS_LEFTX 0
#define PSR_SDL_AXIS_LEFTY 1
#define PSR_SDL_AXIS_RIGHTX 2
#define PSR_SDL_AXIS_RIGHTY 3
#define PSR_SDL_AXIS_TRIGGERLEFT 4
#define PSR_SDL_AXIS_TRIGGERRIGHT 5
#define PSR_SDL_AXIS_COUNT 6

typedef Uint32 (*fn_SDL_WasInit)(Uint32 flags);
typedef int (*fn_SDL_JoystickAttachVirtual)(int type, int naxes, int nbuttons, int nhats);
typedef SDL_Joystick *(*fn_SDL_JoystickOpen)(int device_index);
typedef int (*fn_SDL_JoystickSetVirtualAxis)(SDL_Joystick *joystick, int axis, Sint16 value);
typedef int (*fn_SDL_JoystickSetVirtualButton)(SDL_Joystick *joystick, int button, Uint8 value);

/* External SDL_PollEvent resolved dynamically from host process (chiaki-ng) */
extern int SDL_PollEvent(SDL_Event *event);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

static PsrMapper g_mapper;
static SDL_Joystick *g_vjoy = NULL;
static bool g_initialized = false;
static bool g_failed = false;
static uint64_t g_last_tick_ns = 0;
static mach_timebase_info_data_t g_timebase = {0, 0};

static fn_SDL_WasInit p_SDL_WasInit = NULL;
static fn_SDL_JoystickAttachVirtual p_SDL_JoystickAttachVirtual = NULL;
static fn_SDL_JoystickOpen p_SDL_JoystickOpen = NULL;
static fn_SDL_JoystickSetVirtualAxis p_SDL_JoystickSetVirtualAxis = NULL;
static fn_SDL_JoystickSetVirtualButton p_SDL_JoystickSetVirtualButton = NULL;

static uint64_t now_ns(void) {
    if (g_timebase.denom == 0) {
        mach_timebase_info(&g_timebase);
    }
    return (mach_absolute_time() * g_timebase.numer) / g_timebase.denom;
}

/* Convert trigger [0..32767] to SDL virtual axis [-32768..32767]. */
static Sint16 trigger_to_virtual_axis(int16_t trig) {
    int32_t v = (int32_t)trig * 2 - 32768;
    if (v < -32768) v = -32768;
    if (v > 32767) v = 32767;
    return (Sint16)v;
}

static void init_bridge_on_sdl_thread(void) {
    if (g_initialized || g_failed) return;

    p_SDL_WasInit = (fn_SDL_WasInit)dlsym(RTLD_DEFAULT, "SDL_WasInit");
    p_SDL_JoystickAttachVirtual = (fn_SDL_JoystickAttachVirtual)dlsym(RTLD_DEFAULT, "SDL_JoystickAttachVirtual");
    p_SDL_JoystickOpen = (fn_SDL_JoystickOpen)dlsym(RTLD_DEFAULT, "SDL_JoystickOpen");
    p_SDL_JoystickSetVirtualAxis = (fn_SDL_JoystickSetVirtualAxis)dlsym(RTLD_DEFAULT, "SDL_JoystickSetVirtualAxis");
    p_SDL_JoystickSetVirtualButton = (fn_SDL_JoystickSetVirtualButton)dlsym(RTLD_DEFAULT, "SDL_JoystickSetVirtualButton");

    if (!p_SDL_WasInit || !p_SDL_JoystickAttachVirtual || !p_SDL_JoystickOpen ||
        !p_SDL_JoystickSetVirtualAxis || !p_SDL_JoystickSetVirtualButton) {
        fprintf(stderr, "[senza-chiaki] ERROR: Required SDL2 virtual joystick symbols not found.\n");
        g_failed = true;
        return;
    }

    if ((p_SDL_WasInit(PSR_SDL_INIT_GAMECONTROLLER) & PSR_SDL_INIT_GAMECONTROLLER) == 0) {
        return; /* Wait until chiaki-ng finishes SDL_Init(SDL_INIT_GAMECONTROLLER) */
    }

    PsrConfig cfg;
    const char *cfg_path = getenv("SENZA_PROFILE_CFG");
    if (cfg_path && psr_config_load_file(cfg_path, &cfg)) {
        fprintf(stderr, "[senza-chiaki] Loaded profile: %s\n", cfg_path);
    } else {
        psr_config_init_default(&cfg);
        fprintf(stderr, "[senza-chiaki] Using built-in GTA 6 default profile\n");
    }
    psr_mapper_init(&g_mapper, &cfg);

    int dev_index = p_SDL_JoystickAttachVirtual(
        PSR_SDL_JOYSTICK_TYPE_GAMECONTROLLER,
        PSR_SDL_AXIS_COUNT,
        PSR_BTN_COUNT,
        0
    );
    if (dev_index < 0) {
        fprintf(stderr, "[senza-chiaki] ERROR: SDL_JoystickAttachVirtual failed (%d)\n", dev_index);
        g_failed = true;
        return;
    }

    g_vjoy = p_SDL_JoystickOpen(dev_index);
    if (!g_vjoy) {
        fprintf(stderr, "[senza-chiaki] ERROR: SDL_JoystickOpen(%d) failed\n", dev_index);
        g_failed = true;
        return;
    }

    /* Initialize triggers to released (-32768) */
    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_TRIGGERLEFT, -32768);
    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_TRIGGERRIGHT, -32768);

    const char *disable_tap = getenv("SENZA_DISABLE_EVENT_TAP");
    if (!disable_tap || strcmp(disable_tap, "1") != 0) {
        psr_capture_start(&g_mapper);
    }

    g_last_tick_ns = now_ns();
    g_initialized = true;
    fprintf(stderr, "[senza-chiaki] Virtual DualSense attached (SDL device index %d)\n", dev_index);
    fflush(stderr);
}

static void push_pad_state(void) {
    if (!g_initialized || !g_vjoy) return;

    uint64_t t = now_ns();
    float dt_ms = (float)(t - g_last_tick_ns) / 1000000.0f;
    /* Throttle virtual updates to at least 1ms intervals to avoid zero-dt noise */
    if (dt_ms < 1.0f) return;
    g_last_tick_ns = t;

    PsrPadState pad;
    psr_capture_sample_state(dt_ms, &pad);

    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_LEFTX, pad.lx);
    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_LEFTY, pad.ly);
    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_RIGHTX, pad.rx);
    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_RIGHTY, pad.ry);
    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_TRIGGERLEFT, trigger_to_virtual_axis(pad.l2));
    p_SDL_JoystickSetVirtualAxis(g_vjoy, PSR_SDL_AXIS_TRIGGERRIGHT, trigger_to_virtual_axis(pad.r2));

    for (int i = 0; i < PSR_BTN_COUNT; i++) {
        p_SDL_JoystickSetVirtualButton(g_vjoy, i, pad.buttons[i]);
    }
}

static int my_SDL_PollEvent(SDL_Event *event) {
    if (!g_initialized && !g_failed) {
        init_bridge_on_sdl_thread();
    }
    push_pad_state();
    return SDL_PollEvent(event);
}

DYLD_INTERPOSE(my_SDL_PollEvent, SDL_PollEvent)
