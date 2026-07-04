# Audeon virtual audio driver

A CoreAudio HAL plug-in that presents a virtual device named "Audeon Stream"
to the system, so apps like OBS, Discord, and Zoom can select it directly,
and so all system audio can be funneled into Audeon by picking it as the
default output.

## Status: Stage 2 (installable on a real machine)

The driver was developed against a staged safety plan, because a HAL plug-in
loads into coreaudiod, the system audio daemon, where a bug disrupts audio
for the whole machine:

- Stage 0 (done): the driver is compiled directly into test executables and
  driven through the full AudioServerPlugIn interface the way coreaudiod
  would, including a StartIO / write / read-back / StopIO cycle that verifies
  bit-identical loopback. A crash kills only the test process.
- Stage 1 (skipped by the maintainer's choice): a disposable macOS virtual
  machine round.
- Stage 2 (current): installable on a real machine with a one-command
  recovery script. The device registers and coreaudiod stays healthy;
  wider real-world listening verification is ongoing.

The build is ad hoc signed. It loads on the machine that built it; a signed
and notarized build for general distribution needs an Apple Developer
membership and is planned.

Known behavior: the device exposes its own volume and mute controls, and the
driver applies them to the audio it stores. If the device is the system
default output, the keyboard volume keys change those controls and scale the
captured audio, all the way to silence at zero. The Audeon app pins the
device at full volume, unmuted, while system audio capture is active and
guards it against outside changes; anything else using the device directly
should do the same.

## Install a prebuilt download (no toolchain needed)

Most people should just grab the prebuilt driver from the latest release. It is
a universal build (Apple Silicon and Intel):

```bash
cd ~/Downloads
unzip -o Audeon-Driver-macos.zip
cd Audeon-Driver
sudo ./install.sh                     # clears quarantine, installs, restarts coreaudiod
```

`sudo ./uninstall.sh` removes it again. The prebuilt bundle is ad-hoc signed,
not notarized, so the installer clears the download quarantine for you and it
loads on most Macs; a few with stricter or MDM-managed security may still
refuse an un-notarized system driver, in which case use the free notarized
BlackHole driver (https://existential.audio/blackhole/), which Audeon supports
the same way. `Driver/package-driver.sh` is what produces this zip.

## Build and install from source

```bash
cd Driver
./build-driver.sh                     # build build/AudeonAudio.driver (universal)
sudo ./install-driver.sh              # copy into /Library/Audio/Plug-Ins/HAL and restart coreaudiod
swift Tests/verify_installed.swift    # confirm the device registered (no sudo needed)
```

If system audio ever misbehaves after installing, one command returns the
Mac to normal:

```bash
sudo ./recover-audio.sh
```

## Layout

- `vendor/BlackHole/` - pristine, unmodified source of the BlackHole driver
  (GPL-3.0), which is engineered to be rebranded via preprocessor definitions.
- `AudeonDriverConfig.h` - the Audeon branding and device configuration. The
  single source of truth used by both the build and the tests.
- `build-driver.sh` - builds `build/AudeonAudio.driver` (universal). Build only, no install.
- `package-driver.sh` - builds and assembles the downloadable installer zip.
- `install-driver.sh` - installs the built bundle system-wide (needs sudo).
- `recover-audio.sh` - removes the driver and restarts coreaudiod (needs sudo).
- `Tests/harness.c` - in-process interface, robustness, and loopback tests.
- `Tests/bundle_load.c` - loads the built bundle via CFPlugIn, the same
  mechanism coreaudiod uses, and verifies factory registration and identity.
- `Tests/verify_installed.swift` - post-install check against live CoreAudio.
- `run-stage0.sh` - builds everything and runs both in-process test programs.

## Run the in-process tests

```bash
cd Driver
./run-stage0.sh
```

## Licensing

This `Driver/` directory is licensed under GPL-3.0, because it builds upon
the BlackHole driver source by Existential Audio Inc. The vendored source and
its license text are preserved verbatim in `vendor/BlackHole/`. The Audeon
app itself (everything outside `Driver/`) remains MIT licensed; the app does
not link against the driver, it only sees the resulting CoreAudio device like
any other.

The BlackHole name and branding belong to Existential Audio Inc. and are not
used in the built product, which is exactly the rebranding path the upstream
source supports through its configuration definitions.
