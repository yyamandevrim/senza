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

void *net_telemetry_thread(void *arg) {
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

        bool reachable = avg_ms >= 0.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            hud_net_update(avg_ms, jitter_ms, loss_pct, awdl_up, reachable);
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
