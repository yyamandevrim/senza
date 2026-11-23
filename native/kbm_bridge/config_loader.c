#include "config_loader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static PsrTarget parse_target(const char *name) {
    if (strcmp(name, "CROSS") == 0) return PSR_BTN_CROSS;
    if (strcmp(name, "CIRCLE") == 0) return PSR_BTN_CIRCLE;
    if (strcmp(name, "SQUARE") == 0) return PSR_BTN_SQUARE;
    if (strcmp(name, "TRIANGLE") == 0) return PSR_BTN_TRIANGLE;
    if (strcmp(name, "SHARE") == 0) return PSR_BTN_SHARE;
    if (strcmp(name, "PS") == 0) return PSR_BTN_PS;
    if (strcmp(name, "OPTIONS") == 0) return PSR_BTN_OPTIONS;
    if (strcmp(name, "L3") == 0) return PSR_BTN_L3;
    if (strcmp(name, "R3") == 0) return PSR_BTN_R3;
    if (strcmp(name, "L1") == 0) return PSR_BTN_L1;
    if (strcmp(name, "R1") == 0) return PSR_BTN_R1;
    if (strcmp(name, "DPAD_UP") == 0) return PSR_BTN_DPAD_UP;
    if (strcmp(name, "DPAD_DOWN") == 0) return PSR_BTN_DPAD_DOWN;
    if (strcmp(name, "DPAD_LEFT") == 0) return PSR_BTN_DPAD_LEFT;
    if (strcmp(name, "DPAD_RIGHT") == 0) return PSR_BTN_DPAD_RIGHT;
    if (strcmp(name, "MIC") == 0) return PSR_BTN_MIC;
    if (strcmp(name, "TOUCHPAD") == 0) return PSR_BTN_TOUCHPAD;
    if (strcmp(name, "L2") == 0) return PSR_TRIGGER_L2;
    if (strcmp(name, "R2") == 0) return PSR_TRIGGER_R2;
    return PSR_TARGET_NONE;
}

static void trim_newline(char *s) {
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ' || s[len - 1] == '\t')) {
        s[--len] = '\0';
    }
}

bool psr_config_load_file(const char *path, PsrConfig *cfg) {
    if (!path || !cfg) return false;
    FILE *fp = fopen(path, "r");
    if (!fp) return false;

    psr_config_init_default(cfg);
    bool saw_on_foot = false;
    bool saw_vehicle = false;
    bool saw_aircraft = false;

    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        trim_newline(line);
        if (line[0] == '\0' || line[0] == '#') continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        const char *key = line;
        const char *val = eq + 1;

        if (strcmp(key, "toggle_capture_key") == 0) cfg->toggle_capture_key = atoi(val);
        else if (strcmp(key, "toggle_vehicle_key") == 0) cfg->toggle_vehicle_key = atoi(val);
        else if (strcmp(key, "toggle_aircraft_key") == 0) cfg->toggle_aircraft_key = atoi(val);
        else if (strcmp(key, "toggle_smart_key") == 0) cfg->toggle_smart_key = atoi(val);
        else if (strcmp(key, "rstick_hold_key") == 0) cfg->rstick_hold_key = atoi(val);
        else if (strcmp(key, "hotwire_assist_key") == 0) cfg->hotwire_assist_key = atoi(val);
        else if (strcmp(key, "circle_assist_key") == 0) cfg->circle_assist_key = atoi(val);
        else if (strcmp(key, "rapid_tap_key") == 0) cfg->rapid_tap_key = atoi(val);
        else if (strcmp(key, "cruise_toggle_key") == 0) cfg->cruise_toggle_key = atoi(val);
        else if (strcmp(key, "smart_vehicle_key") == 0) cfg->smart_vehicle_key = atoi(val);
        else if (strcmp(key, "sens_down_key") == 0) cfg->sens_down_key = atoi(val);
        else if (strcmp(key, "sens_up_key") == 0) cfg->sens_up_key = atoi(val);
        else if (strcmp(key, "mic_mute_key") == 0) cfg->mic_mute_key = atoi(val);
        else if (strcmp(key, "smart_mode_default") == 0) cfg->smart_mode_default = (atoi(val) != 0);
        else if (strcmp(key, "smart_haptics") == 0) cfg->smart_haptics = (atoi(val) != 0);
        else if (strcmp(key, "move_up_key") == 0) cfg->move_up_key = atoi(val);
        else if (strcmp(key, "move_down_key") == 0) cfg->move_down_key = atoi(val);
        else if (strcmp(key, "move_left_key") == 0) cfg->move_left_key = atoi(val);
        else if (strcmp(key, "move_right_key") == 0) cfg->move_right_key = atoi(val);
        else if (strcmp(key, "walk_mod_key") == 0) cfg->walk_mod_key = atoi(val);
        else if (strcmp(key, "walk_scale") == 0) cfg->walk_scale = strtof(val, NULL);
        else if (strcmp(key, "sensitivity") == 0) cfg->sensitivity = strtof(val, NULL);
        else if (strcmp(key, "ads_sensitivity_scale") == 0) cfg->ads_sensitivity_scale = strtof(val, NULL);
        else if (strcmp(key, "sniper_sensitivity_scale") == 0) cfg->sniper_sensitivity_scale = strtof(val, NULL);
        else if (strcmp(key, "deadzone") == 0) cfg->deadzone = strtof(val, NULL);
        else if (strcmp(key, "curve_exponent") == 0) cfg->curve_exponent = strtof(val, NULL);
        else if (strcmp(key, "smoothing") == 0) cfg->smoothing = strtof(val, NULL);
        else if (strcmp(key, "decay_half_life_ms") == 0) cfg->decay_half_life_ms = strtof(val, NULL);
        else if (strcmp(key, "max_velocity_px_per_sec") == 0) cfg->max_velocity_px_per_sec = strtof(val, NULL);
        else if (strcmp(key, "invert_y") == 0) cfg->invert_y = (atoi(val) != 0);
        else if (strcmp(key, "trackpad_mode") == 0) cfg->trackpad_mode = (atoi(val) != 0);
        else if (strcmp(key, "trackpad_accel") == 0) cfg->trackpad_accel = strtof(val, NULL);
        else if (strncmp(key, "on_foot.", 8) == 0) {
            if (!saw_on_foot) {
                cfg->on_foot_count = 0;
                saw_on_foot = true;
            }
            int code = atoi(key + 8);
            PsrTarget t = parse_target(val);
            if (t != PSR_TARGET_NONE && cfg->on_foot_count < PSR_MAX_BINDINGS) {
                cfg->on_foot[cfg->on_foot_count].input_code = code;
                cfg->on_foot[cfg->on_foot_count].target = t;
                cfg->on_foot_count++;
            }
        } else if (strncmp(key, "vehicle.", 8) == 0) {
            if (!saw_vehicle) {
                cfg->vehicle_count = 0;
                saw_vehicle = true;
            }
            int code = atoi(key + 8);
            PsrTarget t = parse_target(val);
            if (t != PSR_TARGET_NONE && cfg->vehicle_count < PSR_MAX_BINDINGS) {
                cfg->vehicle[cfg->vehicle_count].input_code = code;
                cfg->vehicle[cfg->vehicle_count].target = t;
                cfg->vehicle_count++;
            }
        } else if (strncmp(key, "aircraft.", 9) == 0) {
            if (!saw_aircraft) {
                cfg->aircraft_count = 0;
                saw_aircraft = true;
            }
            int code = atoi(key + 9);
            PsrTarget t = parse_target(val);
            if (t != PSR_TARGET_NONE && cfg->aircraft_count < PSR_MAX_BINDINGS) {
                cfg->aircraft[cfg->aircraft_count].input_code = code;
                cfg->aircraft[cfg->aircraft_count].target = t;
                cfg->aircraft_count++;
            }
        }
    }

    fclose(fp);
    return true;
}
