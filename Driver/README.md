# Audeon virtual audio driver

A CoreAudio HAL plug-in that presents a virtual device named "Audeon Stream"
to the system, so apps like OBS, Discord, and Zoom can select it directly,
and so all system audio can be funneled into Audeon by picking it as the
default output.

## Status: Stage 0 (in-process testing only)

Nothing here installs anything. The driver is developed against a staged
safety plan, because a HAL plug-in loads into coreaudiod, the system audio
daemon, where a bug disrupts audio for the whole machine:

- Stage 0 (this directory, done): the driver is compiled directly into test
  executables and driven through the full AudioServerPlugIn interface the way
  coreaudiod would, including a StartIO / write / read-back / StopIO cycle
  that verifies bit-identical loopback. A crash kills only the test process.
- Stage 1 (next): install into a disposable macOS virtual machine and hammer
  it there. The host Mac never loads the plug-in.
- Stage 2 (last): install on a real machine, with a prepared one-command
  recovery script.

## Layout

- `vendor/BlackHole/` - pristine, unmodified source of the BlackHole driver
  (GPL-3.0), which is engineered to be rebranded via preprocessor definitions.
- `AudeonDriverConfig.h` - the Audeon branding and device configuration. The
  single source of truth used by both the build and the tests.
- `build-driver.sh` - builds `build/AudeonAudio.driver`. Build only, no install.
- `Tests/harness.c` - in-process interface, robustness, and loopback tests.
- `Tests/bundle_load.c` - loads the built bundle via CFPlugIn, the same
  mechanism coreaudiod uses, and verifies factory registration and identity.
- `run-stage0.sh` - builds everything and runs both test programs.

## Run Stage 0

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
