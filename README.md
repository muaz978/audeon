# Audeon

<img src="Icon/Audeon-icon-1024.png" alt="Audeon icon" width="160" />

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

## The routing canvas

One canvas, the way the original works:

- Add input picks a source, which can be a capture device (a microphone or
  interface) or a running application. Each source becomes a card on the left.
- Add output picks an output device. Each becomes a card on the right.
- Drag from a source card's pin to an output card's pin to connect them, or click
  the source pin and then click an output pin. A cable is drawn and audio flows.
- Many to one is supported: several sources can feed one output, and one source
  can feed several outputs.

## Features

- Add device or application inputs, and output devices, on a single canvas.
- Drag a pin to an output to connect, or click one pin then the other.
- A real audio engine. Both device and application sources run through an
  AVAudioEngine with a 10 band EQ. Application sources are captured with a Core
  Audio process tap and replayed directly to the chosen output, so you can send
  one app to your headphones only.
- Per input volume, mute, a 1x to 4x volume boost, and a 10 band EQ with presets.
- Per output volume and mute.
- Connect one input to several outputs. Each input lists its connected outputs,
  and you can disconnect any one of them from the card.
- Click a cable to delete just that connection.
- Drag inputs or outputs to reorder them.
- Hide inactive applications in the Add input list.
- Color customizable cards and cables, with smooth animations, saved between
  launches.
- A tabbed Settings window: start at login, theme, system default devices, and a
  cleanup tool for leftover capture devices.
- A menu bar panel to tweak each input's volume, mute, and boost without opening
  the window.

## Requirements

- macOS 14 (Sonoma) or later. Per-app redirect needs macOS 14.2 or later, since
  it relies on Core Audio process taps; the rest works on 14.0.
- The Swift toolchain (install Xcode, or the Command Line Tools with
  `xcode-select --install`).

## Install a release build

Releases ship a zipped `.app`. The build is ad hoc signed, not notarized, so
macOS quarantines it after download and a normal double click is refused. Open
Terminal and paste these commands to unzip it, clear the quarantine flag, and
launch it:

```bash
cd ~/Downloads
unzip -o Audeon-0.1.0-macos.zip
xattr -dr com.apple.quarantine Audeon.app
mv Audeon.app /Applications/
open /Applications/Audeon.app
```

If macOS still blocks it, run the binary directly to confirm it works:

```bash
/Applications/Audeon.app/Contents/MacOS/Audeon
```

If you would rather not use Terminal, unzip in Finder, right click Audeon.app,
choose Open, then confirm. You only need to do this once.

## Build and run from source

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

1. Click Add input and pick a device or a running app. It appears as a card on
   the left.
2. Click Add output and pick an output device. It appears as a card on the right.
3. Drag from the source card's pin to the output card's pin to connect them, or
   click the source pin and then click an output pin. A cable is drawn and audio
   flows.
4. Connect as many cables as you like. Several inputs can feed one output.
5. Use each card's slider and mute button to set levels.
6. Set the system default Output, Input, and Sound Effects devices in Settings.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| Settings | Cmd-, |
| Refresh Devices & Apps | Cmd-R |
| Disconnect All | Shift-Cmd-K |

## How it works

| File | Role |
|------|------|
| `Audio/AudioDeviceManager.swift` | CoreAudio device enumeration and a hot plug change listener |
| `Audio/AudioRouter.swift` | One AVAudioEngine per device-to-device route, with gain |
| `Audio/AppAudioManager.swift` | Auto-detects running apps via the Core Audio process object list |
| `Audio/AppRedirectEngine.swift` | Per app and output process tap, private aggregate device, gain passthrough |
| `Audio/SystemAudioController.swift` | Reads and sets the default Output, Input, and Sound Effects devices |
| `Audio/DeviceControls.swift` | Per-device volume and sample rate |
| `Models/GraphModels.swift` | Input sources, output targets, and connection value types |
| `Models/MixerStore.swift` | Graph state, persistence, drag-connect, and engine sync |
| `Models/Route.swift` | Route and color palette used by the device router |
| `Views/RoutingCanvasView.swift` | The canvas: Add input or output, cards, pins, and cables |
| `Views/ContentView.swift` | Window chrome and the menu button |
| `Views/SettingsView.swift` | Settings sheet with system default device pickers |
| `AudeonApp.swift` | App entry point, native menus, and the menu bar control |

The canvas (inputs, outputs, connections, and colors) is stored in
`~/Library/Application Support/Audeon/graph.json`.

## Roadmap

Done so far: a Mixline style routing canvas (add input/output, click or drag to
connect, many to one and one to many), per-source and per-output volume and
mute, a 10 band EQ and 1x-4x volume overdrive per source, Magic Boost (a
dynamics compressor that lifts quiet audio and tames peaks), live level meters
on cards and in the menu bar, system default device pickers, per-device volume
and sample rate, scenes (save and recall a whole routing setup), follow system
output, a menu bar quick controls popover, a first run permissions screen, and
sleep/wake and device hot-plug resilience.

Known limitation: routing between two different physical devices (for example
a USB microphone to a separate set of speakers) uses a private aggregate
device combining the two, the same technique proven reliable for per-app
capture. In testing this surfaced a sample rate and channel count validation
issue in some configurations, which fails safely (a banner appears, no crash,
no audio glitch) but does not yet guarantee sound reaches the output. Routing
where the input and output are the same device, and all per-app capture and
redirect, are unaffected. This needs real-world listening verification, which
is tracked as the top priority below.

Still planned, in rough priority order:

1. Verify and, if needed, rework cross-device hardware routing using a lower
   level technique (a direct I/O proc on the aggregate device, the same
   primitive already used for per-app capture) instead of binding
   AVAudioEngine's shared input/output unit to the aggregate.
2. Output Groups, so one app can play to several devices at once.
3. Present Audeon as a virtual device for OBS, Streamlabs, and Discord. In
   progress in `Driver/`: an AudioServerPlugIn built on the BlackHole source
   (GPL-3.0, see `Driver/README.md`), currently at Stage 0 of a staged safety
   plan (in-process tests only, nothing installed). Until it ships, the
   onboarding screen detects and recommends the BlackHole driver itself.
4. Recording a mix to a file, reusing the existing tap pipeline.
5. Super volume keys and a global show or hide shortcut, both opt in and both
   needing Accessibility access.
6. Per-device custom icon, and broader VoiceOver labeling.

## License

MIT. See `LICENSE`.
