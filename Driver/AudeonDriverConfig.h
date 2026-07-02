// Branding and device configuration for the Audeon virtual audio driver.
//
// The driver is built from the vendored BlackHole source (see vendor/BlackHole,
// GPL-3.0), which is designed to be rebranded through these preprocessor
// definitions. This header is the single source of truth: the build script
// force-includes it when compiling the .driver bundle, and the Stage 0 test
// harness includes it before including the driver source, so the tested
// configuration is always the shipped configuration.

#ifndef AUDEON_DRIVER_CONFIG_H
#define AUDEON_DRIVER_CONFIG_H

// The user-visible device is "Audeon Stream". With the name format disabled,
// the device UID becomes "Audeon_UID" and the model UID "Audeon_ModelUID".
#define kDriver_Name                "Audeon"
#define kHas_Driver_Name_Format     false
#define kDevice_Name                "Audeon Stream"
#define kManufacturer_Name          "Audeon"
#define kPlugIn_BundleID            "io.github.muaz978.audeon.driver"
#define kPlugIn_Icon                "Audeon.icns"

// Two channels, standard rates. The vendored source supplies sensible
// defaults for everything not defined here.
#define kNumber_Of_Channels         2

#endif
