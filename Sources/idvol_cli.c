// idvol — command-line test / reverse-engineering tool for Audient iD interfaces.
//
//   idvol                          detect
//   idvol <0.0-1.0> [phones]       set speaker (or headphone) level
//   idvol dim|mono|alt|polarity|mute|talkback on|off
//
//   Read-only exploration (never changes settings — but see the note on scan):
//   idvol info                     dump USB interfaces, endpoints and audio entities
//   idvol probe                    try reading back every control we know about
//   idvol watch [ms]               poll the readable known controls, print changes
//   idvol meters [log]             live view (or CSV log to stdout) of of the mixer memory blocks Audient's app polls
//                                  (probably meters); prints min/max per value on Ctrl-C
//   idvol idbutton [mono|monopol|dim|talkback|alt]   read or set the iD button's function
//   idvol events                   live view of the iD's change queue (what the iD app polls)
//   idvol phones-mute on|off       headphone mute
//   idvol sniff                    listen to everything the iD sends on its HID interface,
//                                  plus live speaker level / mute (Ctrl-C to stop)
//   idvol scan [entity …] [--cs LO-HI] [--cn LO-HI]
//                                  read controls, you make a change, read again, show diffs
//                                  (default: mixer/monitor/feature units; skips routing,
//                                   which can hang the iD's firmware until power-cycled)
#include "AudientUSB.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>

// UAC2 "CUR" (0x01) and UAC1 "GET_CUR" (0x81) — try both.
static const uint8_t kReqs[] = {0x01, 0x81};

typedef struct {
    const char *name;
    uint16_t wValue;
    uint8_t entity;
    uint8_t len;
} Control;

static const Control kKnown[] = {
    {"speaker level", 0x1200, 0x36, 2}, {"phones L", 0x0205, 0x0a, 2}, {"phones R", 0x0206, 0x0a, 2},
    {"phones mute", 0x0105, 0x0a, 1},
    {"mono", 0x0000, 0x36, 1},          {"polarity", 0x0300, 0x36, 1}, {"speaker mute", 0x0400, 0x36, 1},
    {"dim", 0x0500, 0x36, 1},           {"talkback", 0x0700, 0x36, 1}, {"alt", 0x0c00, 0x36, 1},
};
#define N_KNOWN (sizeof(kKnown) / sizeof(kKnown[0]))

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void print_bytes(const uint8_t *b, int n) {
    for (int i = 0; i < n; i++) printf("%02x ", b[i]);
    if (n == 2) {
        int16_t v = (int16_t)(b[0] | (b[1] << 8));
        double pos = v == INT16_MIN ? 0.0 : 1.0 - (v / 256.0) / AUD_DEFAULT_FLOOR_DB;
        printf(" (int16 %d, ~%.0f%% on the app's scale)", v, pos * 100.0);
    }
}

// ---------------------------------------------------------------- info

static const char *ep_type(uint8_t attr) {
    static const char *t[] = {"control", "isochronous", "bulk", "INTERRUPT"};
    return t[attr & 3];
}

static const char *ac_subtype(uint8_t s) {
    switch (s) {
        case 0x01: return "AC header";
        case 0x02: return "input terminal";
        case 0x03: return "output terminal";
        case 0x04: return "mixer unit";
        case 0x05: return "selector unit";
        case 0x06: return "feature unit";
        case 0x07: return "effect/processing unit";
        case 0x08: return "processing/extension unit";
        case 0x09: return "extension unit";
        case 0x0a: return "clock source";
        case 0x0b: return "clock selector";
        case 0x0c: return "clock multiplier";
        default: return "other";
    }
}

static int cmd_info(void) {
    const uint8_t *d = NULL;
    int total = aud_config_descriptor(&d);
    if (total <= 0) {
        fprintf(stderr, "Couldn't read the configuration descriptor.\n");
        return 2;
    }
    int cur_class = -1;
    for (int i = 0; i + 2 <= total && d[i] >= 2; i += d[i]) {
        const uint8_t *x = d + i;
        switch (x[1]) {
            case 0x04:
                cur_class = x[5];
                printf("\nInterface %d alt %d: class 0x%02x sub 0x%02x proto 0x%02x, %d endpoint(s)\n", x[2], x[3],
                       x[5], x[6], x[7], x[4]);
                break;
            case 0x05:
                printf("    endpoint 0x%02x %-5s %s, max packet %d, interval %d\n", x[2], (x[2] & 0x80) ? "IN" : "OUT",
                       ep_type(x[3]), x[4] | (x[5] << 8), x[6]);
                break;
            case 0x24:
                if (cur_class == 0x01 && x[2] >= 0x02)
                    printf("    audio entity 0x%02x: %s\n", x[3], ac_subtype(x[2]));
                break;
            case 0x0b:
                printf("\n(interface association: first %d, count %d)\n", x[2], x[3]);
                break;
        }
    }
    printf("\n");
    return 0;
}

// ---------------------------------------------------------------- probe

static int cmd_probe(void) {
    printf("\nReading back known controls (0x01 = UAC2 CUR, 0x81 = UAC1 GET_CUR):\n\n");
    for (size_t i = 0; i < N_KNOWN; i++) {
        for (size_t r = 0; r < sizeof(kReqs); r++) {
            uint8_t buf[4] = {0};
            int n = aud_read(kReqs[r], kKnown[i].wValue, kKnown[i].entity, buf, kKnown[i].len, 300);
            printf("  %-14s req 0x%02x  wValue 0x%04x entity 0x%02x: ", kKnown[i].name, kReqs[r], kKnown[i].wValue,
                   kKnown[i].entity);
            if (n < 0) printf("no (0x%08x)\n", (unsigned)n);
            else { printf("OK  "); print_bytes(buf, n); printf("\n"); }
        }
    }
    printf("\n");
    return 0;
}

// ---------------------------------------------------------------- watch

static int cmd_watch(int interval_ms) {
    typedef struct { const Control *c; uint8_t req; uint8_t last[4]; int n; } W;
    W w[N_KNOWN * 2];
    int count = 0;
    for (size_t i = 0; i < N_KNOWN; i++)
        for (size_t r = 0; r < sizeof(kReqs); r++) {
            uint8_t buf[4] = {0};
            int n = aud_read(kReqs[r], kKnown[i].wValue, kKnown[i].entity, buf, kKnown[i].len, 300);
            if (n > 0) {
                w[count].c = &kKnown[i];
                w[count].req = kReqs[r];
                w[count].n = n;
                memcpy(w[count].last, buf, 4);
                count++;
            }
        }
    if (count == 0) {
        printf("None of the known controls can be read back — try `idvol scan` instead.\n");
        return 3;
    }
    printf("Watching %d readable control(s) every %d ms. Turn the knob, press buttons. Ctrl-C to stop.\n\n", count,
           interval_ms);
    for (int i = 0; i < count; i++) {
        printf("  start  %-14s (req 0x%02x): ", w[i].c->name, w[i].req);
        print_bytes(w[i].last, w[i].n);
        printf("\n");
    }
    double t0 = now_ms();
    for (;;) {
        for (int i = 0; i < count; i++) {
            uint8_t buf[4] = {0};
            int n = aud_read(w[i].req, w[i].c->wValue, w[i].c->entity, buf, w[i].c->len, 300);
            if (n > 0 && (n != w[i].n || memcmp(buf, w[i].last, n) != 0)) {
                printf("  %6.1fs %-14s: ", (now_ms() - t0) / 1000.0, w[i].c->name);
                print_bytes(buf, n);
                printf("\n");
                fflush(stdout);
                memcpy(w[i].last, buf, 4);
                w[i].n = n;
            }
        }
        usleep(interval_ms * 1000);
    }
}

// ---------------------------------------------------------------- meters
//
// Audient's app constantly reads four memory blocks from the mixer unit (entity 0x3c)
// with the UAC2 MEM request (bRequest 0x03), using exactly these offsets and lengths.
// We copy those requests exactly — never other lengths — and show the values live.

static const struct { uint16_t offset; uint16_t len; } kMeterBlocks[] = {{0, 32}, {1, 12}, {2, 16}, {3, 6}};
#define N_BLOCKS 4
static volatile sig_atomic_t g_stop = 0;
static void on_sigint(int sig) { (void)sig; g_stop = 1; }

static int cmd_meters(int log_mode) {
    uint16_t mn[N_BLOCKS][16], mx[N_BLOCKS][16];
    for (int b = 0; b < N_BLOCKS; b++)
        for (int i = 0; i < 16; i++) { mn[b][i] = 0xffff; mx[b][i] = 0; }
    signal(SIGINT, on_sigint);
    double t0 = now_ms();
    int samples = 0;
    if (log_mode) {  // one CSV line per reading: time, then every value of every block
        printf("t_ms");
        for (int b = 0; b < N_BLOCKS; b++)
            for (int ch = 0; ch < kMeterBlocks[b].len / 2; ch++) printf(",b%d_%d", b, ch + 1);
        printf("\n");
        while (!g_stop) {
            printf("%.0f", now_ms() - t0);
            for (int b = 0; b < N_BLOCKS; b++) {
                uint8_t buf[32] = {0};
                int n = aud_read(0x03, kMeterBlocks[b].offset, 0x3c, buf, kMeterBlocks[b].len, 200);
                for (int i = 0; i + 1 < kMeterBlocks[b].len; i += 2)
                    printf(",%d", n > i ? (buf[i] | (buf[i + 1] << 8)) : -1);
            }
            printf("\n");
            fflush(stdout);
            usleep(50 * 1000);
        }
        return 0;
    }
    while (!g_stop) {
        printf("\033[H\033[J");  // redraw in place
        printf("iD mixer memory blocks (entity 0x3c, MEM) — %.0fs, %d samples. Ctrl-C for summary.\n\n",
               (now_ms() - t0) / 1000.0, samples);
        for (int b = 0; b < N_BLOCKS; b++) {
            uint8_t buf[32] = {0};
            int n = aud_read(0x03, kMeterBlocks[b].offset, 0x3c, buf, kMeterBlocks[b].len, 200);
            printf("  block %d (%2d bytes): ", b, kMeterBlocks[b].len);
            if (n < 0) { printf("read failed (0x%08x)\n", (unsigned)n); continue; }
            for (int i = 0; i + 1 < n; i += 2) {
                uint16_t v = (uint16_t)(buf[i] | (buf[i + 1] << 8));
                int ch = i / 2;
                if (v < mn[b][ch]) mn[b][ch] = v;
                if (v > mx[b][ch]) mx[b][ch] = v;
                printf("%6u", v);
            }
            printf("\n");
        }
        samples++;
        fflush(stdout);
        usleep(100 * 1000);
    }
    printf("\n\nSummary — min..max per value (paste this):\n");
    for (int b = 0; b < N_BLOCKS; b++) {
        printf("  block %d:", b);
        for (int ch = 0; ch < kMeterBlocks[b].len / 2; ch++)
            printf("  [%d] %u..%u", ch + 1, mn[b][ch] == 0xffff ? 0 : mn[b][ch], mx[b][ch]);
        printf("\n");
    }
    return 0;
}

// ---------------------------------------------------------------- events

static const char *describe(uint8_t cs, uint8_t cn, uint8_t e) {
    static char buf[64];
    if (e == 0x36 && cs == 0x12) return "speaker level";
    if (e == 0x36 && cs == 0x04) return "speaker mute";
    if (e == 0x36 && cs == 0x05) return "dim";
    if (e == 0x36 && cs == 0x00) return "mono";
    if (e == 0x36 && cs == 0x0c) return "alt";
    if (e == 0x36 && cs == 0x03) return "polarity";
    if (e == 0x36 && cs == 0x07) return "talkback";
    if (e == 0x36 && cs == 0x10) return "iD button assignment";
    if (e == 0x0a && cs == 0x02 && (cn == 4 || cn == 5)) return "HEADPHONE volume";
    if (e == 0x0a && cs == 0x01 && (cn == 4 || cn == 5)) return "HEADPHONE mute";
    snprintf(buf, sizeof buf, "unknown");
    return buf;
}

static int cmd_events(void) {
    printf("\nWatching the change queue. Use the knob and buttons; Ctrl-C to stop.\n\n");
    double t0 = now_ms();
    for (;;) {
        uint8_t cs, cn, e;
        int r = aud_read_change_event(&cs, &cn, &e);
        if (r == 1) {
            printf("  %6.2fs  entity 0x%02x CS 0x%02x ch %d changed  → %s", (now_ms() - t0) / 1000.0, e, cs, cn + 1,
                   describe(cs, cn, e));
            // Read the new value the same way Audient's app does.
            uint8_t b[2] = {0};
            int n = aud_read(0x01, (uint16_t)((cs << 8) | (cn + 1)), e, b, cs == 0x02 || cs == 0x12 ? 2 : 1, 200);
            if (e == 0x36 && cs == 0x12) n = aud_read(0x01, 0x1200, 0x36, b, 2, 200);  // speaker is channel 0
            if (n > 0) { printf("   now: "); print_bytes(b, n); }
            printf("\n");
            fflush(stdout);
            continue;  // drain the queue quickly
        }
        if (r < 0) { printf("  read failed (0x%08x)\n", (unsigned)r); sleep(1); }
        usleep(20 * 1000);
    }
    return 0;
}

// ---------------------------------------------------------------- sniff
//
// Interface 3 on the iD is a HID interface with an interrupt IN endpoint — the device
// can push messages to the host on its own. We listen to it non-exclusively (audio is
// unaffected) and print every report, next to the speaker level/mute read back live.

static double g_t0;
static uint8_t g_last_report[256];
static CFIndex g_last_len = -1;
static int g_repeats = 0;
static uint8_t g_last_level[2] = {0xff, 0xff};
static int g_last_mute = -1;

static double t_now(void) { return (now_ms() - g_t0) / 1000.0; }

static long hid_prop(IOHIDDeviceRef dev, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(dev, key);
    long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
    return out;
}

static void flush_repeats(void) {
    if (g_repeats > 0) printf("             (same report repeated %d more time%s)\n", g_repeats, g_repeats == 1 ? "" : "s");
    g_repeats = 0;
}

static void on_report(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID,
                      uint8_t *report, CFIndex len) {
    (void)ctx; (void)result; (void)sender;
    if (len == g_last_len && memcmp(report, g_last_report, (size_t)len) == 0) {
        g_repeats++;
        return;
    }
    flush_repeats();
    printf("  %7.2fs  HID %s report id %u, %ld bytes: ", t_now(), type == kIOHIDReportTypeInput ? "input" : "other",
           reportID, (long)len);
    for (CFIndex i = 0; i < len; i++) printf("%02x ", report[i]);
    printf("\n");
    fflush(stdout);
    CFIndex n = len < (CFIndex)sizeof(g_last_report) ? len : (CFIndex)sizeof(g_last_report);
    memcpy(g_last_report, report, (size_t)n);
    g_last_len = len;
}

static void on_value(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)ctx; (void)result; (void)sender;
    IOHIDElementRef el = IOHIDValueGetElement(value);
    flush_repeats();
    printf("  %7.2fs  HID value  usage page 0x%04x usage 0x%04x = %ld\n", t_now(), IOHIDElementGetUsagePage(el),
           IOHIDElementGetUsage(el), (long)IOHIDValueGetIntegerValue(value));
    fflush(stdout);
}

static void on_matched(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)result; (void)sender;
    long page = hid_prop(dev, CFSTR(kIOHIDPrimaryUsagePageKey));
    long usage = hid_prop(dev, CFSTR(kIOHIDPrimaryUsageKey));
    long in_size = hid_prop(dev, CFSTR(kIOHIDMaxInputReportSizeKey));
    long feat_size = hid_prop(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey));
    long out_size = hid_prop(dev, CFSTR(kIOHIDMaxOutputReportSizeKey));
    printf("  HID device found: usage page 0x%04lx usage 0x%04lx — max input %ld, output %ld, feature %ld bytes\n",
           page, usage, in_size, out_size, feat_size);
    CFIndex size = in_size > 0 ? in_size : 64;
    if (size < 64) size = 64;
    uint8_t *buf = malloc((size_t)size);
    IOHIDDeviceRegisterInputReportCallback(dev, buf, size, on_report, NULL);
    fflush(stdout);
}

static void poll_levels(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    uint8_t b[2] = {0};
    if (aud_read(0x01, 0x1200, 0x36, b, 2, 200) == 2 && memcmp(b, g_last_level, 2) != 0) {
        flush_repeats();
        printf("  %7.2fs  speaker level: ", t_now());
        print_bytes(b, 2);
        printf("\n");
        memcpy(g_last_level, b, 2);
    }
    uint8_t m = 0;
    if (aud_read(0x01, 0x0400, 0x36, &m, 1, 200) == 1 && m != g_last_mute) {
        flush_repeats();
        printf("  %7.2fs  speaker mute:  %d\n", t_now(), m);
        g_last_mute = m;
    }
    fflush(stdout);
}

static int cmd_sniff(void) {
    g_t0 = now_ms();
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vid = 0x2708;
    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    const void *keys[] = {CFSTR(kIOHIDVendorIDKey)};
    const void *vals[] = {vidNum};
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, on_matched, NULL);
    IOHIDManagerRegisterInputValueCallback(mgr, on_value, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    printf("\nListening. Try, one at a time with a pause between:\n"
           "  1) turn the knob (speakers)   2) press the knob\n"
           "  3) press the headphone button   4) turn the knob in headphone mode\n"
           "  5) press the headphone button again\n"
           "Ctrl-C to stop.\n\n");
    IOReturn kr = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (kr != kIOReturnSuccess) {
        printf("  Couldn't open the HID interface (0x%08x).\n", kr);
        if (kr == (IOReturn)0xe00002e2)
            printf("  macOS blocked it: allow Terminal in System Settings → Privacy & Security →\n"
                   "  Input Monitoring, then quit and reopen Terminal and try again.\n");
        return 3;
    }

    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0,
                                                   poll_levels, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return 0;
}

// ---------------------------------------------------------------- scan
//
// Some reads (routing entity 0x33, beyond its real channel count) make the iD's
// firmware stop answering control requests until it is power-cycled. So the scan
// skips routing/clock entities, paces itself, and checks after every control
// selector that the interface still answers; if not, it stops and says where.

typedef struct { uint8_t e, cs, cn, n; uint8_t v[2]; } Hit;
#define MAX_HITS (64 * 32 * 8)

// Mixer / monitor / feature units only. 0x32/0x33 are routing (0x33 wedged the firmware).
static const uint8_t kScanEntities[] = {0x36, 0x37, 0x3e, 0x34, 0x0c, 0x0a, 0x0b};
#define N_SCAN (sizeof(kScanEntities) / sizeof(kScanEntities[0]))

static int still_alive(void) {
    uint8_t b[2];
    return aud_read(0x01, 0x1200, 0x36, b, 2, 300) == 2;
}

typedef struct { int cs_lo, cs_hi, cn_lo, cn_hi; } Range;

// Returns number of hits, or -1 if the interface stopped answering.
static int scan_pass(const uint8_t *ents, int n_ents, Range r, Hit *out) {
    int count = 0;
    for (int i = 0; i < n_ents; i++) {
        int e = ents[i];
        for (int cs = r.cs_lo; cs <= r.cs_hi; cs++) {
            printf("\r  entity 0x%02x  CS 0x%02x…", e, cs);
            fflush(stdout);
            for (int cn = r.cn_lo; cn <= r.cn_hi; cn++) {
                uint8_t buf[2] = {0};
                int n = aud_read(0x01, (uint16_t)((cs << 8) | cn), (uint8_t)e, buf, 2, 60);
                if (n > 0 && count < MAX_HITS) {
                    Hit h = {(uint8_t)e, (uint8_t)cs, (uint8_t)cn, (uint8_t)n, {buf[0], buf[1]}};
                    out[count++] = h;
                } else if (n <= 0 && !still_alive()) {
                    // A failed read is normal (control doesn't exist) — unless the iD then stops answering.
                    printf("\n\n  STOPPED: reading entity 0x%02x CS 0x%02x CN 0x%02x made the interface stop answering.\n"
                           "  Power-cycle the iD, then continue after it, e.g.:\n"
                           "    idvol scan 0x%02x --cs 0x%02x-0x%02x\n\n",
                           e, cs, cn, e, cs + 1, r.cs_hi);
                    return -1;
                }
                usleep(1000);
            }
        }
    }
    printf("\r                                   \r");
    return count;
}

static void print_hit(const Hit *h) {
    printf("    entity 0x%02x CS 0x%02x CN 0x%02x: ", h->e, h->cs, h->cn);
    print_bytes(h->v, h->n);
    printf("\n");
}

static int cmd_scan(const uint8_t *ents, int n_ents, Range r) {
    static Hit before[MAX_HITS], after[MAX_HITS];
    if (!still_alive()) {
        printf("The interface isn't answering reads. Power-cycle it (switch off/on or unplug USB) and retry.\n");
        return 3;
    }
    printf("\nScanning entities:");
    for (int i = 0; i < n_ents; i++) printf(" 0x%02x", ents[i]);
    printf("  (CS 0x%02x-0x%02x, CN 0x%02x-0x%02x)\n\nPass 1…\n", r.cs_lo, r.cs_hi, r.cn_lo, r.cn_hi);
    int nb = scan_pass(ents, n_ents, r, before);
    if (nb < 0) return 4;
    printf("  %d readable control(s).\n", nb);
    for (int i = 0; i < nb; i++) print_hit(&before[i]);

    printf("\nNow make the change you're investigating — e.g. press the HEADPHONE button\n"
           "and turn the knob a good way — then press Enter here… ");
    fflush(stdout);
    getchar();

    printf("Pass 2…\n");
    int na = scan_pass(ents, n_ents, r, after);
    if (na < 0) return 4;

    int changes = 0;
    printf("\nChanged:\n");
    for (int j = 0; j < nb; j++) {
        int found = 0;
        for (int i = 0; i < na; i++)
            if (after[i].e == before[j].e && after[i].cs == before[j].cs && after[i].cn == before[j].cn) {
                found = 1;
                if (after[i].n != before[j].n || memcmp(after[i].v, before[j].v, after[i].n) != 0) {
                    printf("  entity 0x%02x CS 0x%02x CN 0x%02x:  ", after[i].e, after[i].cs, after[i].cn);
                    print_bytes(before[j].v, before[j].n);
                    printf("  →  ");
                    print_bytes(after[i].v, after[i].n);
                    printf("\n");
                    changes++;
                }
                break;
            }
        if (!found) {
            printf("  entity 0x%02x CS 0x%02x CN 0x%02x: no longer readable\n", before[j].e, before[j].cs,
                   before[j].cn);
            changes++;
        }
    }
    if (changes == 0) printf("  (nothing)\n");
    printf("\n");
    return 0;
}

// ---------------------------------------------------------------- main

int main(int argc, char **argv) {
    // Optional:  --iface N  (anywhere) — send requests to interface N instead of the spare one.
    int iface = -1;
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "--iface") == 0 && i + 1 < argc) {
            iface = atoi(argv[i + 1]);
            for (int j = i; j + 2 <= argc; j++) argv[j] = argv[j + 2];
            argc -= 2;
            break;
        }
    int pid = aud_connect();
    if (iface >= 0) aud_set_interface_override(iface);
    if (pid < 0) {
        fprintf(stderr, "No Audient iD interface found.\n");
        return 1;
    }
    printf("Found %s (pid 0x%04x), control interface %d%s\n", aud_product_name(pid), pid, aud_control_interface(),
           iface >= 0 ? " (forced with --iface)" : aud_has_spare_interface() ? " (spare DFU/vendor)" : " (fallback 0)");
    if (argc < 2) {
        printf("usage: idvol <0.0-1.0> [phones] | dim|mono|alt|polarity|mute|talkback on|off | phones-mute on|off | info | probe | watch [ms] | idbutton [fn] | events | meters | sniff | scan [entity …]\n");
        return 0;
    }

    if (strcmp(argv[1], "info") == 0) return cmd_info();
    if (strcmp(argv[1], "probe") == 0) return cmd_probe();
    if (strcmp(argv[1], "sniff") == 0) return cmd_sniff();
    if (strcmp(argv[1], "events") == 0) return cmd_events();
    if (strcmp(argv[1], "idbutton") == 0) {
        static const struct { const char *name; int code; } kFns[] = {
            {"mono", AUD_IDBTN_MONO}, {"monopol", AUD_IDBTN_MONO_POLARITY}, {"dim", AUD_IDBTN_DIM},
            {"talkback", AUD_IDBTN_TALKBACK}, {"alt", AUD_IDBTN_ALT}};
        if (argc > 2) {
            for (int i = 0; i < 5; i++)
                if (strcmp(argv[2], kFns[i].name) == 0) {
                    int kr = aud_set_id_button(kFns[i].code);
                    printf("iD button -> %s (0x%02x): %s (0x%08x)\n", kFns[i].name, kFns[i].code,
                           kr == 0 ? "OK" : "FAILED", kr);
                    return kr == 0 ? 0 : 2;
                }
            printf("unknown function — use mono, monopol, dim, talkback or alt\n");
            return 1;
        }
        int v = -1;
        int kr = aud_read_id_button(&v);
        const char *name = "unknown";
        for (int i = 0; i < 5; i++) if (kFns[i].code == v) name = kFns[i].name;
        if (kr == 0) printf("iD button: %s (0x%02x)\n", name, v);
        else printf("read failed (0x%08x)\n", kr);
        return kr == 0 ? 0 : 2;
    }
    if (strcmp(argv[1], "meters") == 0) return cmd_meters(argc > 2 && strcmp(argv[2], "log") == 0);
    if (strcmp(argv[1], "phones-mute") == 0) {
        int on = argc > 2 && (strcmp(argv[2], "on") == 0 || strcmp(argv[2], "1") == 0);
        int kr = aud_set_headphone_mute(on);
        printf("phones mute %s: %s via %s (0x%08x)\n", on ? "on" : "off", kr == 0 ? "OK" : "FAILED", aud_last_path(), kr);
        return kr == 0 ? 0 : 2;
    }
    if (strcmp(argv[1], "watch") == 0) return cmd_watch(argc > 2 ? atoi(argv[2]) : 100);
    if (strcmp(argv[1], "scan") == 0) {
        // idvol scan [entity …] [--cs LO-HI] [--cn LO-HI]
        uint8_t ents[16];
        int n = 0;
        Range r = {0x00, 0x1f, 0x00, 0x07};
        for (int i = 2; i < argc; i++) {
            if ((strcmp(argv[i], "--cs") == 0 || strcmp(argv[i], "--cn") == 0) && i + 1 < argc) {
                char *dash = NULL;
                long lo = strtol(argv[i + 1], &dash, 0);
                long hi = (dash && *dash == '-') ? strtol(dash + 1, NULL, 0) : lo;
                if (argv[i][3] == 's') { r.cs_lo = (int)lo; r.cs_hi = (int)hi; }
                else { r.cn_lo = (int)lo; r.cn_hi = (int)hi; }
                i++;
            } else if (n < 16) {
                ents[n++] = (uint8_t)strtol(argv[i], NULL, 0);
            }
        }
        if (n == 0) return cmd_scan(kScanEntities, (int)N_SCAN, r);
        return cmd_scan(ents, n, r);
    }

    const char *names[] = {"mono", "dim", "alt", "polarity", "mute", "talkback"};
    for (int i = 0; i < 6; i++) {
        if (strcmp(argv[1], names[i]) == 0) {
            int on = argc > 2 && (strcmp(argv[2], "on") == 0 || strcmp(argv[2], "1") == 0);
            int kr = aud_set_monitor_switch(i, on);
            printf("%s %s: %s via %s (0x%08x)\n", names[i], on ? "on" : "off", kr == 0 ? "OK" : "FAILED",
                   aud_last_path(), kr);
            aud_disconnect();
            return kr == 0 ? 0 : 2;
        }
    }
    double p = atof(argv[1]);
    int16_t raw = aud_raw_from_position(p, AUD_DEFAULT_FLOOR_DB);
    int phones = argc > 2 && strcmp(argv[2], "phones") == 0;
    int kr = phones ? aud_set_headphone_raw(raw) : aud_set_speaker_raw(raw);
    printf("%s -> raw %d (0x%04x): %s via %s (0x%08x)\n", phones ? "phones" : "speakers", raw, (uint16_t)raw,
           kr == 0 ? "OK" : "FAILED", aud_last_path(), kr);
    aud_disconnect();
    return kr == 0 ? 0 : 2;
}
