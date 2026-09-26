#include "AudientUSB.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <math.h>
#include <string.h>

#define AUDIENT_VID 0x2708

static IOUSBDeviceInterface182 **g_dev = NULL;
static io_service_t g_ctl_service = IO_OBJECT_NULL;   // spare DFU/vendor interface
static IOUSBInterfaceInterface190 **g_intf = NULL;     // opened lazily, fallback path only
static int g_iface = 0;
static int g_has_spare = 0;
static int g_pid = -1;
static const char *g_last_path = "none";

static const struct { uint16_t pid; const char *name; } kModels[] = {
    {0x0002, "iD14"},     {0x0008, "iD14 MKII"}, {0x0003, "iD4"},
    {0x0009, "iD4 MKII"}, {0x0001, "iD22"},      {0x000d, "iD24"},
    {0x0005, "iD44"},     {0x000b, "iD44 MKII"}, {0x0012, "iD48"},
};
#define N_MODELS (sizeof(kModels) / sizeof(kModels[0]))

const char *aud_product_name(int pid) {
    for (size_t i = 0; i < N_MODELS; i++)
        if (kModels[i].pid == pid) return kModels[i].name;
    return "Audient iD";
}

static int known_pid(int pid) {
    for (size_t i = 0; i < N_MODELS; i++)
        if (kModels[i].pid == pid) return 1;
    return 0;
}

static int prop_int(io_registry_entry_t e, const char *key, int *out) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    if (!v) return 0;
    int ok = 0;
    if (CFGetTypeID(v) == CFNumberGetTypeID())
        ok = CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, out) ? 1 : 0;
    CFRelease(v);
    return ok;
}

// Returns a retained service for the first known Audient device, or IO_OBJECT_NULL.
static io_service_t find_device(int *pid_out) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS)
        return IO_OBJECT_NULL;
    io_service_t svc, found = IO_OBJECT_NULL;
    while ((svc = IOIteratorNext(it))) {
        int vid = 0, pid = 0;
        if (prop_int(svc, "idVendor", &vid) && vid == AUDIENT_VID &&
            prop_int(svc, "idProduct", &pid) && known_pid(pid)) {
            found = svc;
            *pid_out = pid;
            break;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

void aud_disconnect(void) {
    if (g_intf) {
        (*g_intf)->USBInterfaceClose(g_intf);
        (*g_intf)->Release(g_intf);
        g_intf = NULL;
    }
    if (g_dev) {
        (*g_dev)->Release(g_dev);
        g_dev = NULL;
    }
    if (g_ctl_service) {
        IOObjectRelease(g_ctl_service);
        g_ctl_service = IO_OBJECT_NULL;
    }
    g_pid = -1;
    g_iface = 0;
    g_has_spare = 0;
}

int aud_connect(void) {
    aud_disconnect();
    int pid = -1;
    io_service_t dev = find_device(&pid);
    if (!dev) return -1;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(dev, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) {
        IOObjectRelease(dev);
        return -1;
    }
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182),
                                         (LPVOID *)&g_dev);
    IODestroyPlugInInterface(plug);
    if (hr != S_OK || !g_dev) {
        g_dev = NULL;
        IOObjectRelease(dev);
        return -1;
    }

    // Like MixiD: aim requests at the spare DFU/vendor interface so CoreAudio
    // keeps the audio interfaces and playback is never interrupted.
    io_iterator_t kids = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(dev, kIOServicePlane, &kids) == KERN_SUCCESS) {
        io_registry_entry_t k;
        while ((k = IOIteratorNext(kids))) {
            int cls = -1, num = -1;
            if (!g_ctl_service && IOObjectConformsTo(k, "IOUSBHostInterface") &&
                prop_int(k, "bInterfaceClass", &cls) && prop_int(k, "bInterfaceNumber", &num) &&
                (cls == 0xFE || cls == 0xFF)) {
                g_ctl_service = k;  // keep the reference
                g_iface = num;
                g_has_spare = 1;
                continue;
            }
            IOObjectRelease(k);
        }
        IOObjectRelease(kids);
    }
    IOObjectRelease(dev);
    g_pid = pid;
    return pid;
}

int aud_probe(void) {
    int pid = -1;
    io_service_t dev = find_device(&pid);
    if (!dev) {
        aud_disconnect();
        return -1;
    }
    IOObjectRelease(dev);
    if (g_dev && pid == g_pid) return pid;
    return aud_connect();
}

int aud_current_pid(void) { return g_pid; }
int aud_control_interface(void) { return g_iface; }
int aud_has_spare_interface(void) { return g_has_spare; }
const char *aud_last_path(void) { return g_last_path; }

static int open_ctl_interface(void) {
    if (g_intf) return 1;
    if (!g_ctl_service) return 0;
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(g_ctl_service, kIOUSBInterfaceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plug, &score) != KERN_SUCCESS || !plug)
        return 0;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID190), (LPVOID *)&g_intf);
    IODestroyPlugInInterface(plug);
    if (!g_intf) return 0;
    if ((*g_intf)->USBInterfaceOpen(g_intf) != kIOReturnSuccess) {
        (*g_intf)->Release(g_intf);
        g_intf = NULL;
        return 0;
    }
    return 1;
}

// Class-specific SET_CUR, host->device, interface recipient (bmRequestType 0x21).
static IOReturn send_request(uint16_t wValue, uint8_t entity, uint8_t *data, uint16_t len) {
    if (!g_dev && aud_connect() < 0) return kIOReturnNoDevice;

    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof(req));
    req.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface);
    req.bRequest = 0x01;
    req.wValue = wValue;
    req.wIndex = (uint16_t)((entity << 8) | (g_iface & 0xFF));
    req.wLength = len;
    req.pData = data;
    req.noDataTimeout = 500;
    req.completionTimeout = 500;

    // Path 1: default pipe via the device (no exclusive open needed).
    IOReturn kr = (*g_dev)->DeviceRequestTO(g_dev, &req);
    if (kr == kIOReturnSuccess) {
        g_last_path = "device";
        return kr;
    }
    // Path 2: open the spare interface and use its control pipe.
    if (open_ctl_interface()) {
        req.wLenDone = 0;
        IOReturn kr2 = (*g_intf)->ControlRequestTO(g_intf, 0, &req);
        if (kr2 == kIOReturnSuccess) {
            g_last_path = "interface";
            return kr2;
        }
    }
    g_last_path = "failed";
    return kr;
}

static IOReturn send_bytes_retry(uint16_t wValue, uint8_t entity, uint8_t *data, uint16_t len) {
    IOReturn kr = send_request(wValue, entity, data, len);
    if (kr != kIOReturnSuccess && aud_connect() >= 0)  // e.g. unplugged and replugged
        kr = send_request(wValue, entity, data, len);
    return kr;
}

static IOReturn send_retry(uint16_t wValue, uint8_t entity, int16_t raw) {
    uint8_t b[2] = {(uint8_t)(raw & 0xFF), (uint8_t)(((uint16_t)raw >> 8) & 0xFF)};  // little-endian
    return send_bytes_retry(wValue, entity, b, 2);
}

int aud_set_speaker_raw(int16_t raw) { return (int)send_retry(0x1200, 0x36, raw); }

int aud_set_headphone_raw(int16_t raw) {
    IOReturn a = send_retry(0x0203, 0x0a, raw);
    IOReturn b = send_retry(0x0204, 0x0a, raw);
    return (int)(a != kIOReturnSuccess ? a : b);
}

// Selectors from MixiD's masterVals, sent to the monitor entity (0x36).
int aud_set_monitor_switch(int which, int on) {
    static const uint16_t kSelectors[] = {0x0000 /* mono */, 0x0500 /* dim */,
                                          0x0c00 /* alt */, 0x0300 /* polarity */};
    if (which < 0 || which > 3) return (int)kIOReturnBadArgument;
    uint8_t b = on ? 1 : 0;
    return (int)send_bytes_retry(kSelectors[which], 0x36, &b, 1);
}

int16_t aud_raw_from_position(double p, double floor_db) {
    if (!(p > 0.005)) return INT16_MIN;  // silence
    if (p > 1.0) p = 1.0;
    // Assumes 1/256 dB units (standard USB Audio). Linear-in-dB fader.
    double v = round(floor_db * (1.0 - p) * 256.0);
    if (v > -1.0) v = -1.0;        // never exceed MixiD's maximum
    if (v < -32767.0) v = -32767.0;
    return (int16_t)v;
}
