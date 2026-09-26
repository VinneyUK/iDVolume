// AudientUSB — minimal native macOS (IOKit) control of Audient iD monitor volume.
// Protocol taken from MixiD (github.com/TheOnlyJoey/MixiD, MIT).
#ifndef AUDIENT_USB_H
#define AUDIENT_USB_H

#include <stdint.h>

#define AUD_DEFAULT_FLOOR_DB (-64.0)

// Connect (or reconnect) to the first Audient iD device. Returns USB product ID or -1.
int aud_connect(void);
// Cheap presence check; connects if needed. Returns product ID or -1.
int aud_probe(void);
void aud_disconnect(void);

int aud_current_pid(void);
int aud_control_interface(void);
int aud_has_spare_interface(void);
const char *aud_product_name(int pid);
const char *aud_last_path(void);

// Slider position 0..1 -> raw 16-bit value the iD expects.
// 0 = silence (0x8000), 1 = MixiD's max (0xFFFF / -1).
int16_t aud_raw_from_position(double position, double floor_db);

// 0 on success, otherwise an IOReturn code.
int aud_set_speaker_raw(int16_t raw);
int aud_set_headphone_raw(int16_t raw);

// Monitor switches (write-only; the iD can't be read back yet).
#define AUD_SW_MONO 0
#define AUD_SW_DIM 1
#define AUD_SW_ALT 2
#define AUD_SW_POLARITY 3
int aud_set_monitor_switch(int which, int on);

#endif
