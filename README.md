# Audeon

Audeon is a native macOS audio routing and monitoring app for streamers, gamers,
podcasters, and anyone who needs to send several audio sources to several
destinations at once. You build a routing matrix on a simple two column canvas,
set independent levels per route, and monitor everything live.

This is a standalone project. It is not related to, and shares no code with, any
other repository on this account.

## Why it exists

The idea is inspired by the kind of "draw a line from a source to a destination"
audio routers that exist on Windows, which have no Apple equivalent for casual
creators. Audeon rebuilds that workflow from scratch on top of Apple frameworks
(CoreAudio and AVAudioEngine for sound, SwiftUI for the interface), so it feels
at home on macOS with native menus, keyboard shortcuts, a menu bar control, and
automatic dark mode.

## Features

- Discovers every CoreAudio input and output, and refreshes automatically when
  you plug or unplug a device.
- Two column canvas: inputs on the left, outputs on the right, with routing lines
  drawn across the middle.
- Click to connect: tap an input dot, then an output dot, to create a route. One
  input can feed many outputs, and one output can be fed by many inputs.
- A real audio engine. Each route runs its own AVAudioEngine wiring the chosen
  input device through a gain stage to the chosen output device. Sample rate
  differences between devices are handled by the mixer node.
- Per route volume, mute, and solo.
- Master controls: Mute All / Unmute All, and Clear Solo.
- Professional metering: each route shows a level bar normalized from dBFS, the
  bar turns amber then red as the signal approaches full scale, and a clip dot
  lights when the signal hits the ceiling.
- A menu bar control for quick muting without raising the main window.
- Color customizable channels, saved between launches.
- Session presets saved to disk, so you can switch between setups instantly.
- Native menus and keyboard shortcuts. Dark mode is automatic.

## Requirements

- macOS 13 (Ventura) or later.
- The Swift toolchain (install Xcode, or the Command Line Tools with
  `xcode-select --install`).

## Build and run

The easy path builds a real `.app` bundle, which is the most reliable way to get
the microphone permission prompt:

```bash
git clone https://github.com/muaz978/audeon.git
cd audeon
./scripts/build-app.sh
```

For an optimized build:

```bash
./scripts/build-app.sh release
```

For quick iteration during development:

```bash
swift build
swift run
```

You can also open the folder in Xcode (File > Open) and run the Audeon scheme.

On first launch macOS asks for microphone access, which is needed to read input
devices. If you miss the prompt, enable it under
System Settings > Privacy & Security > Microphone.

## How to use

1. Connect your microphones and audio interfaces. They appear in the INPUTS
   column on the left, and your speakers and headphones appear in OUTPUTS on the
   right.
2. Tap an input's colored dot. It highlights to show it is waiting to connect.
3. Tap an output's dot. A routing line is drawn and audio starts flowing.
4. Use the MIXER strip at the bottom to adjust volume, mute, solo, watch the
   meter, or disconnect a route.
5. Use Mute All when you need instant silence, or Solo to hear one route on its
   own. Soloing any route silences the rest until you Clear Solo.
6. Save a layout as a preset with Cmd-S, and recall it from the Presets menu.
7. Use the menu bar icon to mute or unmute routes without opening the window.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| Save Preset | Cmd-S |
| Mute All / Unmute All | Shift-Cmd-M |
| Disconnect All | Shift-Cmd-K |
| Refresh Devices | Cmd-R |

## How it works

| File | Role |
|------|------|
| `Audio/AudioDeviceManager.swift` | CoreAudio device enumeration and a hot plug change listener |
| `Audio/AudioRouter.swift` | One AVAudioEngine per route, gain, solo logic, dBFS metering and clip detection |
| `Models/Route.swift` | Route, color palette, and preset value types |
| `Models/MixerStore.swift` | App state, persistence, presets, master controls, engine sync |
| `Views/ContentView.swift` | Toolbar, two column canvas, and the connection overlay |
| `Views/EndpointColumnView.swift` | Input and output cards with connector dots and color pickers |
| `Views/ConnectionsOverlay.swift` | The routing lines, drawn with anchor preferences |
| `Views/RouteInspectorView.swift` | The mixer strips: volume, mute, solo, meters, clip |
| `AudeonApp.swift` | App entry point, native menus, and the menu bar control |

Routing settings and presets are stored in
`~/Library/Application Support/Audeon/config.json`.

## Roadmap

Two larger features are planned. They are intentionally not in this version
because each is a substantial subsystem, and nothing here is faked.

1. Present Audeon as a virtual device that apps like OBS, Streamlabs, and Discord
   can select. The macOS path is a user space AudioServerPlugIn HAL driver. A
   practical first step is to support the open source BlackHole driver as the
   virtual endpoint, then optionally ship a signed and notarized plug in.

2. Per application capture, so you can route one app (for example a chat app) to
   your headphones only while game audio goes to the stream. The macOS path is
   Core Audio process taps (`AudioHardwareCreateProcessTap` with an aggregate
   device), available on macOS 14.2 and later, which needs no kernel extension.

## License

MIT. See `LICENSE`.
