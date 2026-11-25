# LoopDeLoop

A Mac menu-bar app for the **Loupedeck Live**, for when the official software won't update your device and other tools
won't support its firmware. It talks to the device directly over USB, with no Loupedeck software installed, and is
tested on firmware **0.2.5**.

- **Keys:** title, colours, SF Symbols (searchable picker) or your own images, on the 12 touch keys.
- **Actions** on every key, round button and knob, with separate press, hold and release:
  - keyboard shortcuts, typed text, media keys
  - open an app or a URL, shell commands, AppleScript, Shortcuts
  - **Keyboard Maestro** macros, **BetterTouchTool** named triggers, **Alfred** external triggers
  - switch page or profile, device brightness, vibration
- **Knobs:** turn-left and turn-right actions, with labels on the side strips.
- **Round buttons:** set the colour of each LED.
- **Profiles:** pages within each profile, and automatic switching by frontmost app.
- **Export and import** of profiles, with images included, and full backups.
- **A command-line tool and URL scheme**, so scripts, BTT, Keyboard Maestro and Alfred can change keys and pages:

  ```sh
  loopctl set-key 3 --title "On air" --bg ff0000 --symbol mic.fill
  loopctl page next
  open -g 'loopdeloop://label/tl?text=Volume'
  ```

  `loopctl help` lists every command. BTT, Keyboard Maestro and Alfred run scripts with a minimal `PATH`, so call it by
  its full path (`~/.local/bin/loopctl` after *Install Command-Line Tool* in the menu).

## Building

Needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [just](https://github.com/casey/just).

```sh
just test      # LoupedeckKit and LoopCore tests, headless
just run       # build and launch
just install   # Release build to ~/Applications, loopctl to ~/.local/bin
```

To sign with your own team, which keeps the Accessibility and Automation permissions across rebuilds, create
`Signing.local.xcconfig` (see `Signing.xcconfig`).

## Layout

| Path | What |
| --- | --- |
| `Sources/LoupedeckKit` | Device driver: discovery, the WebSocket-over-serial protocol, input events, RGB565 drawing |
| `Sources/LoopCore` | Config, actions, rendering, the engine (connection, watchdog, input routing), control socket, export |
| `Sources/loopctl` | The CLI, a client of the running app |
| `Sources/ldl` | Direct-to-hardware probe (`just ldl info`, `listen`, `demo`, `stress`); quit the app first |
| `App` | The SwiftUI menu-bar app and editor |

## Firmware notes

Two quirks of firmware 0.2.5, found while building this:

- **Some pixel data locks up the device.** For example, the pixel bytes `27 9f` repeated 64 times, sent with an
  all-zero WebSocket mask (which is what most libraries use). The device then ignores everything until the port is
  reopened. LoopDeLoop masks every frame with a random key, which makes this rare. It also reopens the port and
  redraws automatically when a draw isn't acknowledged within a second.
- **The touch ID in byte 5 changes during a touch.** It seems to be pressure. The stable finger slot is byte 0.

## Credits

The protocol is ported from [foxxyz/loupedeck](https://github.com/foxxyz/loupedeck) (MIT); see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
