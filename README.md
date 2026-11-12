<img src="Resources/AppIcon.png" width="128" alt="Cans icon" align="right">

# Cans

A small native macOS menu bar app for Bose headphones: battery, listening
modes or noise cancelling, equalizer and a few settings, without the phone app.

> **Unofficial.** Not affiliated with, endorsed by, or supported by Bose Corporation.
> "Bose" and "QuietComfort" are trademarks of Bose Corporation, used here only to
> describe compatibility.

## Features

- Battery percentage in the menu bar, red at 20% or below
- Low battery notifications at 20% and 10%
- Several pairs at once: each connected pair gets its own state and alerts; pick one in the popover header
- Play the Mac's audio on a chosen pair (switches the default output, like the Sound menu)
- Switch listening modes: Quiet, Aware, Immersion and your custom modes
  (QC Ultra), or the noise cancelling level (QC35 II)
- See paired devices and switch the headphones between them
- 3-band equalizer (treble / mid / bass, −10…+10)
- Toggle auto-pause on removal, auto-answer calls and multipoint
- Choose what the Action button (QC35 II) or the Shortcut button's long press (QC Ultra) does,
  from the actions the headphones report
- QC35 II: self voice (sidetone), auto-off timer
- Optional voice announcement on mode change
- Reconnects automatically: on Bluetooth connect, on wake, and with backoff
- Launch at login

## Supported headphones

| Model | Product ID | Firmware | Status |
|---|---|---|---|
| QuietComfort Ultra Headphones (1st gen) | `0x4066` | 1.6.7 | Tested |
| QuietComfort 35 II | `0x4020` | 4.8.1 | Reading tested; changing settings untested |

Other Bose devices that speak BMAP get a basic profile (battery, name, paired
devices) and will likely work, but haven't been tested. See
[Adding a model](#adding-a-model).

## Install

**Homebrew**

```sh
brew install --cask egno/tap/cans
```

**Manual:** download `Cans-<version>.dmg` or `.zip` from
[Releases](https://github.com/egno/cans/releases) and move `Cans.app` to
`/Applications`.

Cans isn't signed with an Apple Developer ID, so on first launch macOS will say
it can't verify the developer. Open **System Settings → Privacy & Security**,
scroll down and click **Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Cans.app
```

The Homebrew cask does this for you. Pair your headphones with the Mac in
System Settings first; on first launch macOS asks for Bluetooth permission.

Requires macOS 14 or later, on Apple Silicon or Intel.

## Build from source

Requires Xcode 16 or later (Swift 6).

```sh
./scripts/bundle.sh          # builds build/Cans.app (release, ad-hoc signed)
open build/Cans.app
```

On first launch macOS asks for Bluetooth permission.

For development:

```sh
swift test                   # protocol unit tests
swift run Cans            # runs unbundled; uses your terminal's Bluetooth permission
```

Logs:

```sh
/usr/bin/log stream --predicate 'subsystem == "io.github.egno.cans"' --info
```

## How it works

Bose's apps control headphones with an undocumented protocol called **BMAP**.
It runs over a classic Bluetooth serial channel (the RFCOMM channel of the
Serial Port service, UUID `0x1101`: channel 2 on QC Ultra, 8 on QC35 II),
alongside the normal audio connection. Cans finds the channel through SDP and
falls back to the channels its profiles know. Each packet is:

```
[function block, function, operator, payload length, payload...]
```

Cans opens only that control channel, never the audio link, so connecting or
quitting never interrupts playback.

| Package | Purpose |
|---|---|
| `Sources/BMAP` | Packet framing, payload decoders, request builders, and a request/response client. No Bluetooth code, fully unit-tested. |
| `Sources/BMAP/Profiles` | One `ModelProfile` per model: product IDs, fallback channel, supported features, noise control style. |
| `Sources/Cans` | IOBluetooth RFCOMM transport, `HeadphonesManager` (discovery, one `HeadphoneSession` per connected pair), SwiftUI `MenuBarExtra` UI. |
| `Tests/BMAPTests` | Tests using bytes captured from real headphones. |
| `Tests/CansTests` | Session tests against a fake device. |

### Protocol notes (QC Ultra gen 1)

| Address | Operation | Meaning |
|---|---|---|
| `2.2` | GET | Battery `[percent, …]` |
| `1.7` | GET / SETGET `[value, band]` | EQ, `[min, max, value, band]` per band |
| `31.3` | GET / START `[index, announce]` | Current mode (`ff` = unknown until set this session) |
| `31.6` | GET `[index]` | Mode slot config: name at offset 6 (32 bytes), slots 0–9 |
| `1.24`, `1.27` | GET / SETGET `[0/1]` | Auto-pause, auto-answer |
| `1.9` | GET / SETGET `[0x80, 9, action]` | Shortcut button long press `[button, event, action, supported mask (4 bytes)]` |

The `1.9` supported mask is a big-endian bitset over action numbers (bit 0 in the
last byte); other models may add a 4-byte mask of currently unavailable actions.
Writes echo the button and event the device reported.

Reading the full mode list (`31.1`) requires authentication on this model, so
slots are read one by one instead.

### Protocol notes (QC35 II)

| Address | Operation | Meaning |
|---|---|---|
| `1.6` | GET / SETGET `[level]` | Noise cancelling `[level, supported mask]`: 0 off, 1 high, 3 low |
| `1.11` | GET / SETGET `[1, level]` | Self voice `[1, level, supported mask]` |
| `1.9` | GET / SETGET `[0x10, 4, action]` | Action button `[button, event, action, supported mask (1 byte)]` |
| `1.4` | GET / SETGET `[minutes]` | Auto-off: 0, 5, 20, 40, 60 or 180 |
| `1.3` | GET | Voice prompts: bit 5 on, low 5 bits language |

EQ (`1.7`) gets no reply at all, so it must never be requested; there are no
fblock 31 modes and no model name (`0.15`).

## Adding a model

1. Read its product ID (`0.3`; Cans logs it) and find its BMAP channel.
2. Add `Sources/BMAP/Profiles/<Model>.swift` with a `ModelProfile`: product IDs,
   fallback channel, the `Feature`s it answers, and its noise control style
   (`.modes` or `.ancLevels`). List only features the device answers: some
   models time out instead of returning an error.
3. Add it to `ModelRegistry.all` and add decode tests with captured payloads.

The app shows each section only when the profile supports its feature, so no
UI changes are needed unless the model brings a new kind of setting.

## Credits

Protocol knowledge comes from community reverse-engineering work, especially
[bosectl](https://github.com/aaronsb/bosectl) (MIT) and
[based-connect](https://github.com/Denton-L/based-connect).

## License

[MIT](LICENSE)
