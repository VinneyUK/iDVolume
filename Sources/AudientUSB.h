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
// Force the interface number used in wIndex (-1 = automatic: the spare DFU interface).
void aud_set_interface_override(int iface);

// Compatibility ("safe") mode: every command goes to the spare interface (as MixiD does)
// and the app reads nothing back. The user picks the mode in Settings → Setup:
// 1 = iD14 MKII (full features), 0 = compatibility, -1 = automatic from the USB ID.
// It resets to automatic on every (re)connect until the app applies the saved choice,
// so a newly connected untested model is always safe.
void aud_set_mode(int mode);
int aud_safe_mode(void);   // 1 if the connected model is in compatibility mode
// Models whose read-back, change queue and interface-0 behaviour have been verified.
int aud_model_fully_supported(int pid);

// --- Interface setup assistant (safe: descriptors only, plus user-confirmed commands) ---
typedef struct { uint8_t id; uint8_t subtype; uint8_t channels; } AudEntity;
// Audio units listed in the USB configuration descriptor (a standard request, safe on any
// device). channels is filled for feature units. Returns the count, or -1.
int aud_list_audio_entities(AudEntity *out, int max);
uint16_t aud_device_release(void);           // bcdDevice (firmware release)
void aud_set_hp_channel_override(int first); // 0 = default for the model
void aud_set_switch_interface(int pref);     // -2 automatic, -1 spare interface, >=0 that interface
// Which selector (on the monitor entity 0x36) each AUD_SW_* function uses; -1 = default.
void aud_set_switch_selector(int which, int selector);
// Send one monitor-entity selector on/off (the assistant's discovery tests).
int aud_send_monitor_selector(int selector, int on);
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
#define AUD_SW_TALKBACK 5   // the iD also switches Dim with it
#define AUD_SW_COUNT 6
int aud_set_monitor_switch(int which, int on);

// iD button assignment (entity 0x36, CS 0x10). Value = code of the function it controls:
// 0x00 Mono, 0x03 Mono + Polarity, 0x05 Dim, 0x07 Talkback, 0x0c Alt.
// Read EXACTLY as Audient's app does (4 bytes, interface 0): a 2-byte read of this
// control hangs the firmware until power-cycled.
#define AUD_IDBTN_MONO 0x00
#define AUD_IDBTN_MONO_POLARITY 0x03
#define AUD_IDBTN_DIM 0x05
#define AUD_IDBTN_TALKBACK 0x07
#define AUD_IDBTN_ALT 0x0c
int aud_set_id_button(int function);
int aud_read_id_button(int *out);

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
// Peak meters (UAC2 MEM reads on mixer 0x3c, exactly as Audient's app does).
// Linear peak, 65535 = 0 dBFS. inputs[16]: 1-2 mic/line, 3-10 other inputs, 11-16 playback
// from the Mac (pairs 1/2, 3/4, 5/6). outputs[6]: 1-2 speakers, 3-4 line, 5-6 headphones.
int aud_read_meters(uint16_t *inputs16, uint16_t *outputs6);
int aud_read_output_meters(uint16_t *outputs6);   // outputs block only (one request)
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
