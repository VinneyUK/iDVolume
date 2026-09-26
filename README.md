<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="iDVolume icon">
</p>

<h1 align="center">iDVolume</h1>

<p align="center">
  Control your Audient iD interface's monitor volume from the macOS menu bar —<br>
  no reaching for the knob, no heavyweight mixer app.
</p>

<p align="center">
  <img src="docs/screenshot.png" width="320" alt="iDVolume menu bar panel">
</p>

## Features

- **Menu bar sliders** for speaker level and a headphone trim, with mute on each
- **Keyboard volume keys** (F10/F11/F12, Touch Bar) control the iD — only while it's the
  selected output, so built-in speakers and AirPods behave normally. Option+Shift for fine steps.
- **Scroll over the menu bar icon** to change volume
- **On-screen display** when using the keys or scroll (can be turned off)
- **Knob sync** — turn or press the iD's knob and the app follows (with the on-screen display)
- **Monitor switches**: Mute, Dim, Mono, Alt speakers — read back from the interface
- **Restores your level** when the iD powers on (it starts up silent)
- Talks to the interface directly over USB — audio keeps playing, nothing else to install
- Launch at login

## Compatibility

| | |
|---|---|
| macOS | 13 Ventura or later |
| Tested | Audient **iD14 MKII** |
| Should work | iD14, iD4, iD4 MKII, iD22, iD24, iD44, iD44 MKII, iD48 — untested, reports welcome |

## Install

There's no pre-built download yet, so you build it yourself (takes a few seconds).
You need Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/YOUR-USERNAME/iDVolume.git
cd iDVolume
./build.sh
cp -R build/iDVolume.app /Applications/
open /Applications/iDVolume.app
```

The app reads the interface's current level when it starts, so the slider always matches the knob.

### Test from the command line (optional)

```sh
./build/idvol              # detect the interface
./build/idvol 0.3          # speakers to 30%
./build/idvol 0.4 phones   # headphones to 40%
./build/idvol dim on       # dim | mono | alt | polarity | mute — on | off
./build/idvol probe        # read back known controls
./build/idvol watch        # print changes live while you use the hardware
```

## Permissions

The keyboard volume keys need **Accessibility** access (System Settings → Privacy & Security
→ Accessibility). The app asks the first time.

`build.sh` signs with your Apple Development certificate if you have one, which keeps that
permission across rebuilds. Without one it signs ad-hoc and macOS forgets the permission each
build — reset it with:

```sh
tccutil reset Accessibility com.vinneyuk.idvolume
```

## Known limitations

- **The headphone knob can't be followed.** In headphone mode the iD adjusts and mutes the
  headphones internally: it announces *that* the level changed but never reports the value
  (Audient's own app gets the same blank reading). The app's headphone slider and mute are a
  separate digital trim on the headphone output — they work, but don't mirror the knob.
  Speaker level, mute, Dim, Mono and Alt all sync both ways.
- Some control reads make the iD's firmware stop answering until it's power-cycled (routing
  entity `0x33`, monitor entity `0x36` selector `0x10`). The app never reads those; the
  `idvol scan` tool avoids them and stops safely if it finds another.
- The slider curve assumes standard USB Audio units (1/256 dB) over a 64 dB range —
  adjust `AUD_DEFAULT_FLOOR_DB` in `Sources/AudientUSB.h` if it feels off.
- Quit Audient's own iD app while using this, so the two don't fight.

## How it works

The iD's mixer is controlled with USB Audio class `CUR` requests — `SET` to change a control,
`GET` to read it back (the level and switches are polled a few times a second).

| Control | Entity | Selector / channel |
|---|---|---|
| Speaker level | `0x36` | CS `0x12`, ch 0 — 1/256 dB, knob steps are 1 dB |
| Speaker mute / Dim / Mono / Alt | `0x36` | CS `0x04` / `0x05` / `0x00` / `0x0c` |
| Headphone trim / mute (iD14 MKII) | `0x0a` | CS `0x02` / `0x01`, ch 5 and 6 |
| Change queue | `0x3e` | CS `0x06`, 4 bytes: `CS, ch-1, 00, entity`, or `ff … ff` when empty |

Headphone channels and the change queue were found by capturing Audient's own app on Windows. iDVolume sends them
through IOKit to the interface's spare DFU interface, so Core Audio keeps the audio
interfaces and playback isn't interrupted. The volume keys are captured with a `CGEvent` tap.

## Credits

The USB protocol comes from [MixiD](https://github.com/TheOnlyJoey/MixiD) by
[@TheOnlyJoey](https://github.com/TheOnlyJoey) — an unofficial Linux control panel for the
iD series. Thank you!

## Disclaimer

Unofficial. Not affiliated with, endorsed by, or supported by Audient. "Audient" and "iD" are
trademarks of their respective owner. Use at your own risk.

## License

[MIT](LICENSE)
