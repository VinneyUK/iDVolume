# Changelog

All notable changes to iDVolume. Versions are listed newest first.

## 1.8.4

- **Safety fix: iDVolume no longer sends any commands to models other than the iD14 MKII.** On the original iD14, the commands used in compatibility mode — including by the Setup wizard — were being received by its firmware-update interface, which locked the interface up until it was power-cycled. Sorry to everyone affected. The block is at the lowest level, so no feature can get round it. Unsupported models now show a notice, their controls are switched off, and the volume keys are left to macOS. **Send Details to the Developer** shares the interface's USB description (read-only) to help work out safe support in future.
- Internal tidy-up in the visualiser's audio handling, ready for newer versions of Swift.

## 1.8.3

- **Visualiser** in Console strip, showing what your Mac is playing (macOS 14.2 or later), in eight styles: Spectrum, Bars, Spectrogram, Waveform, Oscilloscope, Stereometer (with correlation), Loudness and a needle VU meter. Pick one in Settings → Panel, or double-click the visualiser to cycle through them; the choice is saved. It asks for system audio access the first time; audio is analysed on your Mac and never recorded or sent anywhere. Switch it off in Settings → Panel.
- **Loudness to ITU-R BS.1770-4**: momentary (400 ms), short-term (3 s) and gated integrated loudness in LUFS, plus true peak in dBTP (4× oversampled). Click the display to reset integrated.
- Console strip's level readout sits closer to the dial.
- **Double-click a knob, fader or slider to mute or unmute** that output. (In Ring focus, muting moves from the readout to the knob.)
- **Double-click a level readout to switch between dB and %.** The choice is saved.
- Settings opens in the middle of the main screen, and the panel stays open alongside it so you can see changes as you make them. Clicking the panel's gear again closes Settings.
- **LED glow**: lit segments in the panel's meters glow in their own colour, like real LEDs (stronger in the dark finish).
- **Console strip** has a level meter: a ring of LEDs around the knob showing the speaker output.
- The menu bar meter shows a single mono bar while Mono is on.
- Meters are a little livelier: read 25 times a second (was 20) and fall a touch faster.
- Lower CPU and memory use: the panel's meter is now built from lightweight layers instead of being redrawn as an image 20 times a second (which was pushing memory past 200 MB while it was open); the menu bar icon is only redrawn when its appearance actually changes; the menu bar meter only redraws on a visible change and caches its colour; identical meter readings (silence) are dropped at source; and key LEDs only animate while flashing.

## 1.8.2

- **Accessibility permission now survives updates.** Releases are signed with the same identity every time, so macOS recognises each update as the same app. (One last time after installing this version, you may need to allow it again.)
- **Fix… clears a stale permission itself.** If the switch in Settings shows on but belongs to an older version, Fix… resets iDVolume's entry and asks macOS again — no need to remove and re-add the app.

## 1.8.1

- **New on-screen display in Apple's style**: device name, a slim level bar between speaker icons and a row of step dots, on Liquid Glass (macOS 26) or the classic frosted blur on earlier versions.
- **The panel tells you when the volume keys aren't working** — usually because macOS dropped iDVolume's Accessibility permission after an update — with a **Fix…** button.
- Only one copy of iDVolume runs at a time. Previously two could start at login (for example when macOS reopened the app as well as starting it as a login item).

## 1.8

- **Settings → Setup** (now first in Settings) asks which interface you have: **iD14 MKII** for full features, or **Another iD model** for compatibility mode and a setup wizard. It's pre-selected from your interface's USB ID and saved per interface.
- **Setup wizard for other iD models.** A guided setup finds out what works on yours in about two minutes: it identifies the interface from its USB description, then plays short tests and asks what you heard — speaker and headphone level (trying other channels if needed), headphone mute, and each monitor switch command. From your answers it works out which command does what on your model (Mute, Dim, Mono, Polarity, Talkback, Alt) and whether the front-panel LEDs update. **The setup is safe**: it only sends commands and never reads from the interface; one optional LED step with a small risk asks before it runs.
- The results are saved and used automatically, and **Send Results** opens a pre-filled GitHub issue so support for your model can be built in for everyone.
- **Welcome on first connection** of any interface that isn't recognised as an iD14 MKII, asking the same question.

## 1.7.5

- **Compatibility mode for models other than the iD14 MKII.** iDVolume now only sends commands to untested models (like MixiD) and doesn't read anything back — fixing interfaces (such as the original iD14) locking up until unplugged. Knob sync, meters and the iD button setting stay off on those models unless you choose Settings → Interface → *Use full features anyway*.
- Headphone controls use the right channels for each model.

## 1.7.4

- **Dark knobs and faders in the dark finish**: black anodised caps with a light pointer, instead of white metal.
- Showcase images updated.

## 1.7.3

- **Green LEDs.** "On" indicators on the keys (and the glowing labels in Illuminated keys) are now green. Orange is kept only for the level scale and the update badge.
- **Mute is remembered when you switch outputs.** In Console strip, a muted output keeps flashing red even when the knob is controlling the other one. Compact and Ring focus show a flashing red dot on the Speakers/Phones selector for any muted output.

## 1.7.2

- Scrolling over the menu bar icon, or over any knob or fader in the panel, moves in whole 1 dB steps like the hardware knob. One wheel notch is 1 dB; trackpad "coasting" is ignored, so a flick can't jump to full volume.
- No focus box around knobs and faders when you click them.
- Removed debug logging.

## 1.7.1

- Scrolling over the menu bar icon changes the volume again.

## 1.7

- **Ten panel layouts** in a hardware-style skin — knobs, faders and LED keys. Choose one in Settings → Panel.
- **Settings window**: open it from the gear, with ⌘, or by right-clicking the menu bar icon (which also has Reconnect and Quit).
- **Light, Dark or Auto** appearance.
- **Automatic updates** from GitHub Releases: optional daily check, checksum-verified download, install and restart. Settings → Updates.

## 1.6.2

- Front-panel switches (Mute, Dim, Mono, Alt, headphone mute) now update the iD's LEDs, like Audient's own app.
- Headphone mute is the real hardware mute, and follows the knob press in headphone mode.
- **iD button** setting: choose what the iD button does (Dim, Mono, Mono + Polarity, Alt, Talkback).
- Option for the iD LED to follow the app's buttons.
- Polarity and Talkback controls.

## 1.6.1

- Downloadable universal app (Apple Silicon and Intel) on the Releases page.
- Guide to notarising the app yourself.
- Optional level meter in the menu bar.

## 1.5

- First release: speaker level follows the hardware knob, hardware mute, Dim / Mono / Alt read back from the interface, level restored at power-on, keyboard volume keys, scroll over the icon, on-screen display.
