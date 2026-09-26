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
#define AUD_SW_MUTE 4       // hardware speaker mute (what pressing the knob toggles)
int aud_set_monitor_switch(int which, int on);

// Read-back (confirmed on iD14 MKII: live, follows the hardware knob and buttons).
// 0 on success, otherwise an error code.
int aud_read_speaker_raw(int16_t *out);
// Headphone mute (feature unit 0x0a, channels 5/6 on the iD14 MKII).
int aud_set_headphone_mute(int on);
int aud_read_headphone_mute(int *out);
// The iD's change queue (entity 0x3e, CS 0x06): returns 1 and fills cs/cn/entity if a
// control changed since the last read, 0 if nothing changed, <0 on error.
// cn is 0-based here (channel N+1 in control terms).
int aud_read_change_event(uint8_t *cs, uint8_t *cn, uint8_t *entity);
int aud_read_monitor_switch(int which, int *out);
// Inverse of aud_raw_from_position; levels below the floor clamp to 0.
double aud_position_from_raw(int16_t raw, double floor_db);

// --- Reverse-engineering helpers (read-only) ---
// Class GET request (interface recipient, device->host). Returns bytes read (>= 0)
// or a negative IOReturn code. Device path only, no retries, so scans stay fast.
int aud_read(uint8_t request, uint16_t wValue, uint8_t entity, uint8_t *buf, uint16_t len, uint32_t timeout_ms);
// Pointer to the raw configuration descriptor; returns its length or -1.
int aud_config_descriptor(const uint8_t **out);

#endif
