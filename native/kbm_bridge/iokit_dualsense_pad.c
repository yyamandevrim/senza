#include "config_loader.h"
#include "macos_capture.h"
#include "mapper_core.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

static PsrMapper g_mapper;
static bool g_mapper_ready = false;
static IOHIDDeviceRef g_fake_device = NULL;

static IOHIDManagerRef g_manager = NULL;
static IOHIDDeviceCallback g_match_cb = NULL;
static void *g_match_ctx = NULL;
static CFRunLoopRef g_manager_rl = NULL;
static CFStringRef g_manager_rl_mode = NULL;
static bool g_announced = false;

static uint8_t *g_report_buf = NULL;
static CFIndex g_report_buf_len = 0;
static IOHIDReportCallback g_input_cb = NULL;
static void *g_input_ctx = NULL;
static CFRunLoopRef g_device_rl = NULL;
static CFRunLoopTimerRef g_timer = NULL;

static uint8_t g_seq = 0;
static uint64_t g_last_tick_ns = 0;
static mach_timebase_info_data_t g_timebase = {0, 0};

/* Cached CF property values */
static CFNumberRef g_cf_vid = NULL;
static CFNumberRef g_cf_pid = NULL;
static CFNumberRef g_cf_loc = NULL;
static CFNumberRef g_cf_usage_page = NULL;
static CFNumberRef g_cf_usage = NULL;
static CFNumberRef g_cf_max_in = NULL;
static CFNumberRef g_cf_max_out = NULL;
static CFNumberRef g_cf_max_feat = NULL;
static CFNumberRef g_cf_ver = NULL;
static CFNumberRef g_cf_vid_src = NULL;

static uint64_t now_ns(void) {
    if (g_timebase.denom == 0) {
        mach_timebase_info(&g_timebase);
    }
    return (mach_absolute_time() * g_timebase.numer) / g_timebase.denom;
}

static void ensure_initialized(void) {
    if (g_mapper_ready) return;
    g_mapper_ready = true;

    /* Real CFStringRef cast to IOHIDDeviceRef so CFRetain/CFRelease/CFSet/NSDictionary are 100% safe */
    g_fake_device = (IOHIDDeviceRef)CFStringCreateWithCString(
        kCFAllocatorDefault, "PSRemoteVirtualDualSenseUSB", kCFStringEncodingUTF8
    );

    int32_t vid = 0x054C;      /* Sony Interactive Entertainment */
    int32_t pid = 0x0CE6;      /* DualSense Wireless Controller */
    int32_t loc = 0x14100000;
    int32_t upage = 1;         /* Generic Desktop */
    int32_t usage = 5;         /* Game Pad */
    int32_t max_in = 64;
    int32_t max_out = 48;
    int32_t max_feat = 64;
    int32_t ver = 0x0100;
    int32_t vid_src = 0;

    g_cf_vid = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vid);
    g_cf_pid = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pid);
    g_cf_loc = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &loc);
    g_cf_usage_page = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &upage);
    g_cf_usage = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage);
    g_cf_max_in = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &max_in);
    g_cf_max_out = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &max_out);
    g_cf_max_feat = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &max_feat);
    g_cf_ver = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &ver);
    g_cf_vid_src = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vid_src);

    PsrConfig cfg;
    const char *cfg_path = getenv("SENZA_PROFILE_CFG");
    if (cfg_path && psr_config_load_file(cfg_path, &cfg)) {
        fprintf(stderr, "[senza-sony] Loaded profile: %s\n", cfg_path);
    } else {
        psr_config_init_default(&cfg);
        fprintf(stderr, "[senza-sony] Using built-in GTA 6 MacBook Trackpad profile\n");
    }
    psr_mapper_init(&g_mapper, &cfg);

    const char *disable_tap = getenv("SENZA_DISABLE_EVENT_TAP");
    if (!disable_tap || strcmp(disable_tap, "1") != 0) {
        psr_capture_start(&g_mapper);
    }
    g_last_tick_ns = now_ns();
    fflush(stderr);
}

static uint8_t axis_i16_to_u8(int16_t v) {
    int32_t scaled = ((int32_t)v + 32768) >> 8;
    if (scaled < 0) scaled = 0;
    if (scaled > 255) scaled = 255;
    return (uint8_t)scaled;
}

static uint8_t trigger_i16_to_u8(int16_t v) {
    if (v <= 0) return 0;
    int32_t scaled = ((int32_t)v * 255) / 32767;
    if (scaled > 255) scaled = 255;
    return (uint8_t)scaled;
}

static uint8_t dpad_hat_value(uint8_t up, uint8_t down, uint8_t left, uint8_t right) {
    if (up && right) return 1;
    if (down && right) return 3;
    if (down && left) return 5;
    if (up && left) return 7;
    if (up) return 0;
    if (right) return 2;
    if (down) return 4;
    if (left) return 6;
    return 8; /* Neutral */
}

static void write_le16(uint8_t *p, int16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}

static void write_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static void encode_dualsense_usb_report(const PsrPadState *pad, uint8_t *buf, size_t len) {
    memset(buf, 0, len);
    if (len < 64) return;

    buf[0] = 0x01; /* USB Input Report ID */
    buf[1] = axis_i16_to_u8(pad->lx);
    buf[2] = axis_i16_to_u8(pad->ly);
    buf[3] = axis_i16_to_u8(pad->rx);
    buf[4] = axis_i16_to_u8(pad->ry);
    buf[5] = trigger_i16_to_u8(pad->l2);
    buf[6] = trigger_i16_to_u8(pad->r2);
    buf[7] = g_seq++;

    uint8_t hat = dpad_hat_value(
        pad->buttons[PSR_BTN_DPAD_UP],
        pad->buttons[PSR_BTN_DPAD_DOWN],
        pad->buttons[PSR_BTN_DPAD_LEFT],
        pad->buttons[PSR_BTN_DPAD_RIGHT]
    );
    buf[8] = hat |
        (uint8_t)((pad->buttons[PSR_BTN_SQUARE] ? 1 : 0) << 4) |
        (uint8_t)((pad->buttons[PSR_BTN_CROSS] ? 1 : 0) << 5) |
        (uint8_t)((pad->buttons[PSR_BTN_CIRCLE] ? 1 : 0) << 6) |
        (uint8_t)((pad->buttons[PSR_BTN_TRIANGLE] ? 1 : 0) << 7);

    buf[9] =
        (uint8_t)((pad->buttons[PSR_BTN_L1] ? 1 : 0) << 0) |
        (uint8_t)((pad->buttons[PSR_BTN_R1] ? 1 : 0) << 1) |
        (uint8_t)((pad->l2 > 2000 ? 1 : 0) << 2) |
        (uint8_t)((pad->r2 > 2000 ? 1 : 0) << 3) |
        (uint8_t)((pad->buttons[PSR_BTN_SHARE] ? 1 : 0) << 4) |
        (uint8_t)((pad->buttons[PSR_BTN_OPTIONS] ? 1 : 0) << 5) |
        (uint8_t)((pad->buttons[PSR_BTN_L3] ? 1 : 0) << 6) |
        (uint8_t)((pad->buttons[PSR_BTN_R3] ? 1 : 0) << 7);

    buf[10] =
        (uint8_t)((pad->buttons[PSR_BTN_PS] ? 1 : 0) << 0) |
        (uint8_t)((pad->buttons[PSR_BTN_TOUCHPAD] ? 1 : 0) << 1) |
        (uint8_t)((pad->buttons[PSR_BTN_MIC] ? 1 : 0) << 2);

    /* Neutral IMU (0 gyro, 1g gravity on Y accel) */
    write_le16(&buf[24], 8192);
    uint32_t ts = (uint32_t)((now_ns() / 333ULL) & 0xFFFFFFFFu);
    write_le32(&buf[28], ts);

    /* DualSense Capacitive Touchpad Finger 0 (1920x1080): bit 7 = 0 active, 1 untouched */
    if (pad->touch_active) {
        uint16_t tx = pad->touch_x > 1919 ? 1919 : pad->touch_x;
        uint16_t ty = pad->touch_y > 1079 ? 1079 : pad->touch_y;
        buf[33] = (uint8_t)(pad->touch_id & 0x7F);
        buf[34] = (uint8_t)(tx & 0xFF);
        buf[35] = (uint8_t)(((tx >> 8) & 0x0F) | ((ty & 0x0F) << 4));
        buf[36] = (uint8_t)((ty >> 4) & 0xFF);
    } else {
        buf[33] = 0x80;
    }
    buf[37] = 0x80; /* Finger 1 untouched */

    /* Battery full + USB powered */
    buf[53] = 0x1A;
}

static void report_timer_cb(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    if (!g_input_cb || !g_report_buf || g_report_buf_len < 64) return;

    uint64_t t = now_ns();
    float dt_ms = (float)(t - g_last_tick_ns) / 1000000.0f;
    if (dt_ms < 0.5f) dt_ms = 4.0f;
    g_last_tick_ns = t;

    PsrPadState pad;
    psr_capture_sample_state(dt_ms, &pad);
    encode_dualsense_usb_report(&pad, g_report_buf, (size_t)g_report_buf_len);

    g_input_cb(
        g_input_ctx,
        kIOReturnSuccess,
        (void *)g_fake_device,
        kIOHIDReportTypeInput,
        0x01,
        g_report_buf,
        64
    );
}

static void start_report_timer_if_ready(void) {
    if (g_timer || !g_input_cb) return;
    CFRunLoopRef rl = g_device_rl ? g_device_rl : g_manager_rl;
    if (!rl) return;

    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    g_timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.01,
        0.004, /* 250 Hz native DualSense USB polling */
        0,
        0,
        report_timer_cb,
        &ctx
    );
    CFRunLoopAddTimer(rl, g_timer, kCFRunLoopCommonModes);
    fprintf(stderr, "[senza-sony] Virtual USB DualSense 250Hz report stream active!\n");
    fflush(stderr);
}

static void announce_virtual_device_if_ready(void) {
    if (g_announced || !g_match_cb || !g_manager_rl) return;
    g_announced = true;

    CFRunLoopRef rl = g_manager_rl;
    CFRunLoopPerformBlock(rl, kCFRunLoopCommonModes, ^{
        fprintf(stderr, "[senza-sony] Announcing Virtual USB DualSense (054C:0CE6) to RemotePlay.app\n");
        fflush(stderr);
        if (g_match_cb) {
            g_match_cb(g_match_ctx, kIOReturnSuccess, (void *)g_manager, g_fake_device);
        }
    });
    CFRunLoopWakeUp(rl);
}

/* ==================== Interposed IOHIDManager functions ==================== */

static void my_IOHIDManagerRegisterDeviceMatchingCallback(
    IOHIDManagerRef manager,
    IOHIDDeviceCallback callback,
    void *context
) {
    ensure_initialized();
    if (callback) {
        g_manager = manager;
        g_match_cb = callback;
        g_match_ctx = context;
    }
    /* Suppress duplicate raw HID callbacks so RemotePlay binds cleanly to Senza's Virtual USB DualSense
     * while Senza reads any physical DualSense via GameController.framework for zero-conflict hot-swap. */
    IOHIDManagerRegisterDeviceMatchingCallback(manager, NULL, NULL);
}

static void my_IOHIDManagerScheduleWithRunLoop(
    IOHIDManagerRef manager,
    CFRunLoopRef runLoop,
    CFStringRef runLoopMode
) {
    ensure_initialized();
    g_manager = manager;
    g_manager_rl = runLoop;
    g_manager_rl_mode = runLoopMode;
    IOHIDManagerScheduleWithRunLoop(manager, runLoop, runLoopMode);
    announce_virtual_device_if_ready();
}

static IOReturn my_IOHIDManagerOpen(IOHIDManagerRef manager, IOOptionBits options) {
    ensure_initialized();
    g_manager = manager;
    IOReturn r = IOHIDManagerOpen(manager, options);
    announce_virtual_device_if_ready();
    return r;
}

static CFSetRef my_IOHIDManagerCopyDevices(IOHIDManagerRef manager) {
    (void)manager;
    ensure_initialized();
    CFMutableSetRef out = CFSetCreateMutable(kCFAllocatorDefault, 1, &kCFTypeSetCallBacks);
    CFSetAddValue(out, g_fake_device);
    return out;
}

/* ==================== Interposed IOHIDDevice functions ==================== */

static IOReturn my_IOHIDDeviceOpen(IOHIDDeviceRef device, IOOptionBits options) {
    if (device && device == g_fake_device) {
        return kIOReturnSuccess;
    }
    return IOHIDDeviceOpen(device, options);
}

static IOReturn my_IOHIDDeviceClose(IOHIDDeviceRef device, IOOptionBits options) {
    if (device && device == g_fake_device) {
        if (g_timer) {
            CFRunLoopTimerInvalidate(g_timer);
            CFRelease(g_timer);
            g_timer = NULL;
        }
        return kIOReturnSuccess;
    }
    return IOHIDDeviceClose(device, options);
}

static void my_IOHIDDeviceScheduleWithRunLoop(
    IOHIDDeviceRef device,
    CFRunLoopRef runLoop,
    CFStringRef runLoopMode
) {
    if (device && device == g_fake_device) {
        g_device_rl = runLoop;
        (void)runLoopMode;
        start_report_timer_if_ready();
        return;
    }
    IOHIDDeviceScheduleWithRunLoop(device, runLoop, runLoopMode);
}

static void my_IOHIDDeviceUnscheduleFromRunLoop(
    IOHIDDeviceRef device,
    CFRunLoopRef runLoop,
    CFStringRef runLoopMode
) {
    if (device && device == g_fake_device) {
        if (g_timer) {
            CFRunLoopTimerInvalidate(g_timer);
            CFRelease(g_timer);
            g_timer = NULL;
        }
        (void)runLoop;
        (void)runLoopMode;
        return;
    }
    IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, runLoopMode);
}

static CFTypeRef my_IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) {
    if (device && device == g_fake_device && key) {
        if (CFEqual(key, CFSTR(kIOHIDVendorIDKey))) return g_cf_vid;
        if (CFEqual(key, CFSTR(kIOHIDProductIDKey))) return g_cf_pid;
        if (CFEqual(key, CFSTR(kIOHIDTransportKey))) return CFSTR("USB");
        if (CFEqual(key, CFSTR(kIOHIDManufacturerKey))) return CFSTR("Sony Interactive Entertainment");
        if (CFEqual(key, CFSTR(kIOHIDProductKey))) return CFSTR("DualSense Wireless Controller");
        if (CFEqual(key, CFSTR(kIOHIDSerialNumberKey))) return CFSTR("00-11-22-33-44-55");
        if (CFEqual(key, CFSTR(kIOHIDLocationIDKey))) return g_cf_loc;
        if (CFEqual(key, CFSTR(kIOHIDPrimaryUsagePageKey))) return g_cf_usage_page;
        if (CFEqual(key, CFSTR(kIOHIDPrimaryUsageKey))) return g_cf_usage;
        if (CFEqual(key, CFSTR(kIOHIDMaxInputReportSizeKey))) return g_cf_max_in;
        if (CFEqual(key, CFSTR(kIOHIDMaxOutputReportSizeKey))) return g_cf_max_out;
        if (CFEqual(key, CFSTR(kIOHIDMaxFeatureReportSizeKey))) return g_cf_max_feat;
        if (CFEqual(key, CFSTR(kIOHIDVersionNumberKey))) return g_cf_ver;
        if (CFEqual(key, CFSTR(kIOHIDVendorIDSourceKey))) return g_cf_vid_src;
        return NULL;
    }
    return IOHIDDeviceGetProperty(device, key);
}

static IOReturn my_IOHIDDeviceGetReport(
    IOHIDDeviceRef device,
    IOHIDReportType reportType,
    CFIndex reportID,
    uint8_t *report,
    CFIndex *pReportLength
) {
    if (device && device == g_fake_device) {
        if (!report || !pReportLength || *pReportLength <= 0) return kIOReturnBadArgument;
        size_t len = (size_t)*pReportLength;
        memset(report, 0, len);
        report[0] = (uint8_t)reportID;

        if (reportID == 0x05 && len >= 41) {
            /* DualSense USB IMU Calibration (identity non-zero ranges to avoid div-by-zero) */
            /* Gyro biases (bytes 1..6) = 0 */
            write_le16(&report[7], 10000);   /* gyro pitch plus */
            write_le16(&report[9], -10000);  /* gyro pitch minus */
            write_le16(&report[11], 10000);  /* gyro yaw plus */
            write_le16(&report[13], -10000); /* gyro yaw minus */
            write_le16(&report[15], 10000);  /* gyro roll plus */
            write_le16(&report[17], -10000); /* gyro roll minus */
            write_le16(&report[19], 540);    /* gyro speed plus */
            write_le16(&report[21], 540);    /* gyro speed minus */
            write_le16(&report[23], 8192);   /* accel X plus */
            write_le16(&report[25], -8192);  /* accel X minus */
            write_le16(&report[27], 8192);   /* accel Y plus */
            write_le16(&report[29], -8192);  /* accel Y minus */
            write_le16(&report[31], 8192);   /* accel Z plus */
            write_le16(&report[33], -8192);  /* accel Z minus */
            *pReportLength = 41;
        } else if (reportID == 0x09 && len >= 20) {
            /* Pairing / MAC info */
            report[1] = 0x55; report[2] = 0x44; report[3] = 0x33;
            report[4] = 0x22; report[5] = 0x11; report[6] = 0x00;
            report[7] = 0x08; report[8] = 0x25; report[9] = 0x00;
            *pReportLength = 20;
        } else if (reportID == 0x20 && len >= 64) {
            /* Firmware info */
            memcpy(&report[1], "Mar 18 2024", 11);
            memcpy(&report[12], "12:00:00", 8);
            write_le16(&report[20], 0x0001);
            write_le16(&report[22], 0x0001);
            write_le32(&report[24], 0x00000314);
            write_le32(&report[28], 0x00010297);
            *pReportLength = 64;
        }
        (void)reportType;
        return kIOReturnSuccess;
    }
    return IOHIDDeviceGetReport(device, reportType, reportID, report, pReportLength);
}

static IOReturn my_IOHIDDeviceSetReport(
    IOHIDDeviceRef device,
    IOHIDReportType reportType,
    CFIndex reportID,
    const uint8_t *report,
    CFIndex reportLength
) {
    if (device && device == g_fake_device) {
        (void)reportType;
        if (report && reportID == 0x02 && reportLength >= 47) {
            size_t off = (reportLength >= 48 && report[0] == 0x02) ? 1 : 0;
            if ((size_t)reportLength >= off + 47) {
                const uint8_t *p = report + off;
                uint8_t flag0 = p[0];
                uint8_t flag1 = p[1];
                PsrDualSenseFeedback fb;
                memset(&fb, 0, sizeof(fb));
                if (flag0 & 0x03) {
                    fb.rumble_right = p[2];
                    fb.rumble_left = p[3];
                }
                if (flag0 & 0x04) {
                    fb.r2_effect_mode = p[10];
                }
                if (flag0 & 0x08) {
                    fb.l2_effect_mode = p[21];
                }
                if (flag1 & 0x04) {
                    fb.has_lightbar = true;
                    fb.led_r = p[44];
                    fb.led_g = p[45];
                    fb.led_b = p[46];
                }
                psr_capture_on_dualsense_feedback(&fb);
            }
        }
        return kIOReturnSuccess;
    }
    return IOHIDDeviceSetReport(device, reportType, reportID, report, reportLength);
}

static void my_IOHIDDeviceRegisterInputReportCallback(
    IOHIDDeviceRef device,
    uint8_t *report,
    CFIndex reportLength,
    IOHIDReportCallback callback,
    void *context
) {
    if (device && device == g_fake_device) {
        g_report_buf = report;
        g_report_buf_len = reportLength;
        g_input_cb = callback;
        g_input_ctx = context;
        if (callback) {
            start_report_timer_if_ready();
        }
        return;
    }
    IOHIDDeviceRegisterInputReportCallback(device, report, reportLength, callback, context);
}

DYLD_INTERPOSE(my_IOHIDManagerRegisterDeviceMatchingCallback, IOHIDManagerRegisterDeviceMatchingCallback)
DYLD_INTERPOSE(my_IOHIDManagerScheduleWithRunLoop, IOHIDManagerScheduleWithRunLoop)
DYLD_INTERPOSE(my_IOHIDManagerOpen, IOHIDManagerOpen)
DYLD_INTERPOSE(my_IOHIDManagerCopyDevices, IOHIDManagerCopyDevices)
DYLD_INTERPOSE(my_IOHIDDeviceOpen, IOHIDDeviceOpen)
DYLD_INTERPOSE(my_IOHIDDeviceClose, IOHIDDeviceClose)
DYLD_INTERPOSE(my_IOHIDDeviceScheduleWithRunLoop, IOHIDDeviceScheduleWithRunLoop)
DYLD_INTERPOSE(my_IOHIDDeviceUnscheduleFromRunLoop, IOHIDDeviceUnscheduleFromRunLoop)
DYLD_INTERPOSE(my_IOHIDDeviceGetProperty, IOHIDDeviceGetProperty)
DYLD_INTERPOSE(my_IOHIDDeviceGetReport, IOHIDDeviceGetReport)
DYLD_INTERPOSE(my_IOHIDDeviceSetReport, IOHIDDeviceSetReport)
DYLD_INTERPOSE(my_IOHIDDeviceRegisterInputReportCallback, IOHIDDeviceRegisterInputReportCallback)
