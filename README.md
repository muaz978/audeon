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

## Two workspaces

Switch between them with the segmented control in the title bar, or from the menu
button next to the title.

### Apps & System

- A System section to set the default Output, Input, and Sound Effects device,
  with output volume and sample rate controls for the selected output.
- An Applications section that auto-detects every running app the audio system
  knows about, showing its icon and name with a per-app volume control and a
  Redirect Audio To picker. Redirecting captures the app with a Core Audio
  process tap and replays it to the chosen device at the chosen volume, so for
  example you can send a chat app to your headphones only.

### Device Routing

- The original routing matrix for wiring physical inputs to outputs.

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
| `Views/AppsView.swift` | The Apps & System workspace: device pickers, per-app volume and redirect |
| `Views/SettingsView.swift` | The Settings sheet from the menu button |
| `Audio/SystemAudioController.swift` | Reads and sets the default Output, Input, and Sound Effects devices |
| `Audio/AppAudioManager.swift` | Auto-detects running apps via the Core Audio process object list |
| `Audio/AppRedirectEngine.swift` | Per-app process tap, private aggregate device, and gain passthrough |
| `Audio/DeviceControls.swift` | Per-device volume and sample rate |
| `AudeonApp.swift` | App entry point, native menus, and the menu bar control |

Routing settings, presets, and per-app redirects are stored in
`~/Library/Application Support/Audeon/config.json`.

## Roadmap

Done so far: device routing, per-app volume and redirect, system default device
pickers, per-device volume and sample rate, a menu bar control, and a settings
menu.

Still planned, in rough priority order. These are real subsystems, not faked
placeholders, which is why they are staged.

1. Per-app and per-device EQ and audio effects (a 10 band EQ and Audio Unit
   hosting). The path is to run the tapped audio through an AVAudioEngine graph
   with `AVAudioUnitEQ` and `AVAudioUnit` effects instead of the plain gain
   passthrough.
2. Volume boost above 100 percent, which is a software gain greater than one in
   the same passthrough.
3. Output Groups, so one app can play to several devices at once.
4. Present Audeon as a virtual device for OBS, Streamlabs, and Discord, via an
   AudioServerPlugIn driver or by supporting the open source BlackHole driver.
5. Super volume keys, so the media keys control the focused app or device.
6. Per-device nickname and custom icon.

## License

MIT. See `LICENSE`.
