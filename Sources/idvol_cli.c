// idvol — command-line test tool.
//   idvol                     detect
//   idvol <0.0-1.0> [phones]  set speaker (or headphone) level
//   idvol dim|mono|alt|polarity on|off
#include "AudientUSB.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    int pid = aud_connect();
    if (pid < 0) {
        fprintf(stderr, "No Audient iD interface found.\n");
        return 1;
    }
    printf("Found %s (pid 0x%04x), control interface %d%s\n", aud_product_name(pid), pid,
           aud_control_interface(), aud_has_spare_interface() ? " (spare DFU/vendor)" : " (fallback 0)");
    if (argc < 2) {
        printf("usage: idvol <0.0-1.0> [phones] | idvol dim|mono|alt|polarity on|off\n");
        return 0;
    }
    const char *names[] = {"mono", "dim", "alt", "polarity"};
    for (int i = 0; i < 4; i++) {
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
    printf("%s -> raw %d (0x%04x): %s via %s (0x%08x)\n", phones ? "phones" : "speakers", raw,
           (uint16_t)raw, kr == 0 ? "OK" : "FAILED", aud_last_path(), kr);
    aud_disconnect();
    return kr == 0 ? 0 : 2;
}
