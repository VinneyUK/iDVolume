# Changelog

All notable changes to iDVolume. Versions are listed newest first.

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
