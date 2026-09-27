# Recording Audient's iD app (to help add support for your model)

iDVolume only supports the **iD14 MKII** at the moment. To support another model safely, we
need to know exactly which commands **Audient's own iD app** sends to it. You can record that
with free tools on a Windows PC. It only **watches** Audient's app talking to your interface,
as it does every day, so it's safe for your interface.

It takes about 15 minutes, most of it installing.

## What you need

- A **Windows 10 or 11 PC** with an ordinary **Intel or AMD** processor.
  (Not a Mac, and not Windows on ARM: the capture driver doesn't support ARM.)
- Your Audient interface and its USB cable.
- **Audient iD** for Windows, from Audient's website (Support → Downloads, your model).
- **Wireshark** for Windows, from <https://www.wireshark.org/download.html>.
  During installation, **tick "Install USBPcap"** when it's offered. This is the part that
  records USB. (If you miss it, it's also available from <https://github.com/desowin/usbpcap/releases>.)
- **Restart** the PC after installing.

## Recording

1. **Plug in the interface**, open **Audient iD**, and check it can control your interface.
   Then **close Audient iD** again for now.
2. Open **Wireshark**. In the list of interfaces, you'll see one or more entries called
   **USBPcap1**, **USBPcap2**… Click the small **gear** next to each in turn: the one that
   lists your **Audient** interface is the right one.
3. **Privacy:** in that gear window, **untick every device except the Audient**, so the
   recording doesn't include your keyboard or mouse. Then click **Start**.
4. **Open Audient iD**, and follow the steps below **in order**, leaving the pauses so each
   step shows up separately in the recording. Skip anything your model doesn't have.

   | # | Do this in Audient iD | Then wait |
   |---|---|---|
   | 1 | Nothing: just let it connect | 5 seconds |
   | 2 | Turn the **speaker (monitor) volume down** by about 5 steps, slowly | 3 seconds |
   | 3 | Turn it **back up** by about 5 steps | 3 seconds |
   | 4 | Click **Mute** (or Cut) on, then off | 3 seconds after each |
   | 5 | Click **Dim** on, then off | 3 seconds after each |
   | 6 | Click **Mono** on, then off | 3 seconds after each |
   | 7 | Click **Polarity / Ø** on, then off, if present | 3 seconds after each |
   | 8 | Click **Alt** (alternative speakers) on, then off, if present | 3 seconds after each |
   | 9 | Click **Talkback** on, then off, if present | 3 seconds after each |
   | 10 | Turn the **headphone volume** down about 5 steps, then back up | 3 seconds |
   | 11 | On the **interface itself**: turn the **big knob** left a few clicks, then right | 3 seconds |
   | 12 | On the interface: **press the knob** (mute), then press it again | 3 seconds after each |
   | 13 | On the interface: press the **iD button**, then press it again | 3 seconds after each |

5. Back in Wireshark, click the red **Stop** square.
6. **File → Save As…**, choose **pcapng**, and save it as e.g. `iD14-mk1-capture.pcapng`.
7. Send the file, with your model name and firmware version (shown in Audient iD).

That's it. Thank you!

## For the developer: reading the recording

```sh
python3 tools/analyse_capture.py iD14-mk1-capture.pcapng --csv iD14-mk1.csv
```

It lists every USB Audio control request Audient's app sent (SET/GET CUR, RANGE, MEM), with
the entity, interface, control selector (CS), channel (CN) and value, marks the pauses between
steps, and summarises each distinct control, plus which interface numbers were addressed.
