#import "capture_internal.h"

/* ==================== Live Network / AWDL Telemetry ==================== */

bool check_awdl_is_up(void) {
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

void sanitize_ping_host(char *out, size_t out_sz) {
    const char *env = getenv("SENZA_PING_HOST");
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

/* One ping round (3 probes, ~1 s). avg_ms < 0 means no reply. */
static void measure(const char *host, double *avg_ms, double *jitter_ms, double *loss_pct) {
    *avg_ms = -1.0;
    *jitter_ms = 0.0;
    *loss_pct = 100.0;
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "/sbin/ping -c 3 -i 0.2 -W 450 %s 2>/dev/null", host);
    FILE *fp = popen(cmd, "r");
    if (!fp) return;
    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        char *loss_p = strstr(line, "% packet loss");
        if (loss_p) {
            char *scan = loss_p;
            while (scan > line && (isdigit((unsigned char)*(scan - 1)) || *(scan - 1) == '.')) scan--;
            *loss_pct = strtod(scan, NULL);
        }
        char *eq = strstr(line, "min/avg/max/stddev = ");
        if (eq) {
            double mn = 0, av = 0, mx = 0, sd = 0;
            if (sscanf(eq + 21, "%lf/%lf/%lf/%lf", &mn, &av, &mx, &sd) == 4) {
                *avg_ms = av;
                *jitter_ms = sd;
            }
        }
    }
    pclose(fp);
}

static bool quality_watch_enabled(void) {
    const char *env = getenv("SENZA_QUALITY_WATCH");
    return !(env && strcmp(env, "0") == 0);
}

/* Session-wide measuring loop: feeds the ';' pill (every 2 s while shown) and the quality watch
 * (every 5 s in the background) from the same pings, so there is never more than one prober. */
void *net_telemetry_thread(void *arg) {
    (void)arg;
    char host[128];
    sanitize_ping_host(host, sizeof(host));
    SzQualityState quality = {0};
    bool watch = quality_watch_enabled();

    while (atomic_load(&g_running) && (watch || atomic_load(&g_net_visible))) {
        if (!atomic_load(&g_app_active) && !atomic_load(&g_net_visible)) {
            usleep(500000); /* not playing right now: don't probe */
            continue;
        }
        bool awdl_up = check_awdl_is_up();
        double avg_ms, jitter_ms, loss_pct;
        measure(host, &avg_ms, &jitter_ms, &loss_pct);
        if (!atomic_load(&g_running)) break;
        bool reachable = avg_ms >= 0.0;

        if (atomic_load(&g_net_visible)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                hud_net_update(avg_ms, jitter_ms, loss_pct, awdl_up, reachable);
            });
        }
        if (watch) {
            SzQualityEvent ev = sz_quality_step(&quality, avg_ms, jitter_ms, loss_pct, reachable, cap_now_ns() / 1000000ULL);
            if (ev == SZ_QUALITY_DEGRADED) {
                fprintf(stderr, "[senza] quality degraded: %.0f ms, jitter %.1f ms, loss %.0f%%\n", avg_ms, jitter_ms, loss_pct);
                fflush(stderr);
                NSString *detail = reachable
                    ? [NSString stringWithFormat:@"%.0f ms   ±%.1f   %%%.0f kayıp   daha düşük çözünürlük dene", avg_ms,
                                                 jitter_ms, loss_pct]
                    : @"yanıt yok   bağlantını kontrol et";
                dispatch_async(dispatch_get_main_queue(), ^{
                    hud_toast(SZ_TONE_WARN, @"Bağlantı zayıfladı", detail);
                });
            } else if (ev == SZ_QUALITY_RECOVERED) {
                fprintf(stderr, "[senza] quality recovered\n");
                fflush(stderr);
                dispatch_async(dispatch_get_main_queue(), ^{
                    hud_toast(SZ_TONE_GOOD, @"Bağlantı düzeldi", nil);
                });
            }
        }

        int ticks = atomic_load(&g_net_visible) ? 10 : 40; /* + ~1 s ping = 2 s / 5 s cadence */
        for (int i = 0; i < ticks; i++) {
            if (!atomic_load(&g_running)) break;
            if (!watch && !atomic_load(&g_net_visible)) break;
            usleep(100000);
        }
    }

    atomic_store(&g_net_thread_active, false);
    return NULL;
}

void net_telemetry_start(void) {
    static pthread_t thread;
    if (!atomic_exchange(&g_net_thread_active, true)) {
        pthread_create(&thread, NULL, net_telemetry_thread, NULL);
        pthread_detach(thread);
    }
}
