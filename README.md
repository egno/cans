# Cans

A small native macOS menu bar app for Bose QuietComfort Ultra headphones:
battery, listening modes, equalizer and a few settings, without the phone app.

> **Unofficial.** Not affiliated with, endorsed by, or supported by Bose Corporation.
> "Bose" and "QuietComfort" are trademarks of Bose Corporation, used here only to
> describe compatibility.

## Features

- Battery percentage in the menu bar
- Switch listening modes: Quiet, Aware, Immersion and your custom modes
- 3-band equalizer (treble / mid / bass, −10…+10)
- Toggle auto-pause on removal and auto-answer calls
- Optional voice announcement on mode change
- Reconnects automatically: on Bluetooth connect, on wake, and with backoff
- Launch at login

## Supported headphones

| Model | Product ID | Firmware | Status |
|---|---|---|---|
| QuietComfort Ultra Headphones (1st gen) | `0x4066` | 1.6.7 | Tested |

Other Bose devices that speak BMAP on RFCOMM channel 2 (for example QC Ultra
Headphones 2nd gen) will likely work, but haven't been tested.

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
On these headphones it runs over a classic Bluetooth serial channel (RFCOMM
channel 2), alongside the normal audio connection. Each packet is:

```
[function block, function, operator, payload length, payload...]
```

Cans opens only that control channel, never the audio link, so connecting or
quitting never interrupts playback.

| Package | Purpose |
|---|---|
| `Sources/BMAP` | Packet framing, payload decoders, request builders, and a request/response client. No Bluetooth code, fully unit-tested. |
| `Sources/Cans` | IOBluetooth RFCOMM transport, connection management, `@Observable` headphones model, SwiftUI `MenuBarExtra` UI. |
| `Tests/BMAPTests` | Tests using bytes captured from real headphones. |

### Protocol notes (QC Ultra gen 1)

| Address | Operation | Meaning |
|---|---|---|
| `2.2` | GET | Battery `[percent, …]` |
| `1.7` | GET / SETGET `[value, band]` | EQ, `[min, max, value, band]` per band |
| `31.3` | GET / START `[index, announce]` | Current mode (`ff` = unknown until set this session) |
| `31.6` | GET `[index]` | Mode slot config: name at offset 6 (32 bytes), slots 0–9 |
| `1.24`, `1.27` | GET / SETGET `[0/1]` | Auto-pause, auto-answer |

Reading the full mode list (`31.1`) requires authentication on this model, so
slots are read one by one instead.

## Credits

Protocol knowledge comes from community reverse-engineering work, especially
[bosectl](https://github.com/aaronsb/bosectl) (MIT) and
[based-connect](https://github.com/Denton-L/based-connect).

## License

[MIT](LICENSE)
