// Stage 0 harness for the Audeon virtual audio driver.
//
// Compiles the driver source directly into this test executable (the same
// technique the upstream project uses for its own tests) and drives the
// AudioServerPlugIn interface the way coreaudiod would: initialization,
// property queries over the object hierarchy, hostile inputs, and a full
// StartIO / write / read-back / StopIO cycle that verifies audio written to
// the device's output comes back identical on its input.
//
// Everything runs inside this ordinary process. A crash here kills the test,
// not the system audio daemon. Nothing is installed.

#include "../AudeonDriverConfig.h"
#include "../vendor/BlackHole/BlackHole.c"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

// MARK: - Result accounting

static int gPass = 0;
static int gFail = 0;

#define CHECK(cond, name) do { \
    if (cond) { gPass++; printf("PASS  %s\n", name); } \
    else      { gFail++; printf("FAIL  %s\n", name); } \
} while (0)

// MARK: - Fake coreaudiod host

static OSStatus FakePropertiesChanged(AudioServerPlugInHostRef inHost, AudioObjectID inObjectID,
                                      UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses) {
    (void)inHost; (void)inObjectID; (void)inNumberAddresses; (void)inAddresses;
    return 0;
}

static OSStatus FakeCopyFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef* outData) {
    (void)inHost; (void)inKey;
    if (outData) *outData = NULL;
    return kAudioHardwareUnknownPropertyError;   // "nothing stored", driver falls back to defaults
}

static OSStatus FakeWriteToStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef inData) {
    (void)inHost; (void)inKey; (void)inData;
    return 0;
}

static OSStatus FakeDeleteFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey) {
    (void)inHost; (void)inKey;
    return 0;
}

static int gConfigChangeRequests = 0;
static OSStatus FakeRequestDeviceConfigurationChange(AudioServerPlugInHostRef inHost, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo) {
    (void)inHost; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    gConfigChangeRequests++;
    return 0;
}

static AudioServerPlugInHostInterface gFakeHost = {
    FakePropertiesChanged,
    FakeCopyFromStorage,
    FakeWriteToStorage,
    FakeDeleteFromStorage,
    FakeRequestDeviceConfigurationChange,
};

// MARK: - Property helpers

static CFStringRef copyStringProperty(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress addr = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef value = NULL;
    UInt32 outSize = 0;
    OSStatus st = (*gAudioServerPlugInDriverRef)->GetPropertyData(
        gAudioServerPlugInDriverRef, objectID, 0, &addr, 0, NULL, sizeof(CFStringRef), &outSize, &value);
    if (st != 0) return NULL;
    return value;
}

static bool stringPropertyEquals(AudioObjectID objectID, AudioObjectPropertySelector selector, const char* expected) {
    CFStringRef value = copyStringProperty(objectID, selector);
    if (!value) return false;
    char buf[256] = {0};
    bool ok = CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8) && strcmp(buf, expected) == 0;
    if (!ok) printf("      (got \"%s\", expected \"%s\")\n", buf, expected);
    CFRelease(value);
    return ok;
}

int main(void) {
    printf("== Audeon driver Stage 0 harness ==\n");
    printf("Driver compiled in-process. Nothing is installed.\n\n");

    AudioServerPlugInDriverRef ref = gAudioServerPlugInDriverRef;

    // 1. COM plumbing: the factory and QueryInterface, exactly as the HAL uses them.
    void* created = BlackHole_Create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(created == (void*)ref, "factory returns the driver for the AudioServerPlugIn type");
    CHECK(BlackHole_Create(NULL, CFUUIDCreate(NULL)) == NULL, "factory refuses an unknown type UUID");

    void* iface = NULL;
    HRESULT hr = (*ref)->QueryInterface(ref, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface);
    CHECK(hr == 0 && iface != NULL, "QueryInterface(AudioServerPlugInDriverInterface)");
    (*ref)->Release(ref);   // balance the AddRef QueryInterface performed

    // 2. Initialize with the fake host.
    OSStatus st = (*ref)->Initialize(ref, &gFakeHost);
    CHECK(st == 0, "Initialize with fake coreaudiod host");

    // 3. Identity properties: the whole point of the rebrand. The manufacturer
    // that users can see lives on the DEVICE object; the plug-in object's
    // manufacturer is hardcoded upstream to "Apple Inc." (a leftover from the
    // NullAudio sample BlackHole grew from) and is not user-visible, so it is
    // only checked for answering at all, not for its value.
    CHECK(stringPropertyEquals(kObjectID_Device, kAudioObjectPropertyManufacturer, kManufacturer_Name),
          "device manufacturer is \"" kManufacturer_Name "\"");
    {
        CFStringRef plugInMfr = copyStringProperty(kObjectID_PlugIn, kAudioObjectPropertyManufacturer);
        CHECK(plugInMfr != NULL, "plug-in object answers the manufacturer property");
        if (plugInMfr) CFRelease(plugInMfr);
    }
    CHECK(stringPropertyEquals(kObjectID_Device, kAudioObjectPropertyName, kDevice_Name),
          "device name is \"" kDevice_Name "\"");
    CHECK(stringPropertyEquals(kObjectID_Device, kAudioDevicePropertyDeviceUID, kDriver_Name "_UID"),
          "device UID is \"" kDriver_Name "_UID\"");

    // 4. The plug-in's device list contains the device.
    {
        AudioObjectPropertyAddress addr = { kAudioPlugInPropertyDeviceList,
                                            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectID devices[8] = {0};
        UInt32 outSize = 0;
        st = (*ref)->GetPropertyData(ref, kObjectID_PlugIn, 0, &addr, 0, NULL, sizeof(devices), &outSize, devices);
        bool found = false;
        for (UInt32 i = 0; st == 0 && i < outSize / sizeof(AudioObjectID); i++)
            if (devices[i] == kObjectID_Device) found = true;
        CHECK(st == 0 && found, "plug-in device list contains the Audeon device");
    }

    // 5. Stream formats: 32-bit float, the configured channel count.
    {
        AudioObjectPropertyAddress addr = { kAudioStreamPropertyVirtualFormat,
                                            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioStreamBasicDescription fmt = {0};
        UInt32 outSize = 0;
        st = (*ref)->GetPropertyData(ref, kObjectID_Stream_Output, 0, &addr, 0, NULL, sizeof(fmt), &outSize, &fmt);
        CHECK(st == 0 && fmt.mChannelsPerFrame == kNumber_Of_Channels
                     && (fmt.mFormatFlags & kAudioFormatFlagIsFloat) && fmt.mBitsPerChannel == 32,
              "output stream is 32-bit float with the configured channel count");
        st = (*ref)->GetPropertyData(ref, kObjectID_Stream_Input, 0, &addr, 0, NULL, sizeof(fmt), &outSize, &fmt);
        CHECK(st == 0 && fmt.mChannelsPerFrame == kNumber_Of_Channels,
              "input stream reports the configured channel count");
    }

    // 6. Hostile inputs: what a confused host might throw at the driver.
    {
        AudioObjectPropertyAddress addr = { kAudioObjectPropertyName,
                                            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CHECK(!(*ref)->HasProperty(ref, 9999, 0, &addr), "HasProperty on a bogus object ID returns false");

        CFStringRef tiny = NULL;
        UInt32 outSize = 0;
        st = (*ref)->GetPropertyData(ref, kObjectID_Device, 0, &addr, 0, NULL, 1 /* too small */, &outSize, &tiny);
        CHECK(st != 0, "GetPropertyData with an undersized buffer fails cleanly");

        Float32 dummy[64] = {0};
        AudioServerPlugInIOCycleInfo cycle; memset(&cycle, 0, sizeof(cycle));
        st = (*ref)->DoIOOperation(ref, kObjectID_Device, 4242 /* bad stream */, 1,
                                   kAudioServerPlugInIOOperationWriteMix, 16, &cycle, dummy, NULL);
        CHECK(st != 0, "DoIOOperation with a bogus stream ID fails cleanly");
    }

    // 7. Full IO lifecycle with loopback verification.
    {
        const UInt32 frames = 512;
        const UInt32 samples = frames * kNumber_Of_Channels;
        st = (*ref)->StartIO(ref, kObjectID_Device, 1);
        CHECK(st == 0, "StartIO");

        Float64 sampleTime = -1; UInt64 hostTime = 0, seed = 0;
        st = (*ref)->GetZeroTimeStamp(ref, kObjectID_Device, 1, &sampleTime, &hostTime, &seed);
        CHECK(st == 0 && seed != 0, "GetZeroTimeStamp returns a valid timestamp and seed");

        Boolean willDo = false, inPlace = false;
        (*ref)->WillDoIOOperation(ref, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace);
        CHECK(willDo, "device performs WriteMix");
        (*ref)->WillDoIOOperation(ref, kObjectID_Device, 1, kAudioServerPlugInIOOperationReadInput, &willDo, &inPlace);
        CHECK(willDo, "device performs ReadInput");

        // Write a recognizable signal at output sample time T...
        Float32* writeBuf = calloc(samples, sizeof(Float32));
        Float32* readBuf  = calloc(samples, sizeof(Float32));
        for (UInt32 i = 0; i < samples; i++) writeBuf[i] = sinf((Float32)i * 0.01f) * 0.5f;

        const Float64 T = 8192;
        AudioServerPlugInIOCycleInfo cycle; memset(&cycle, 0, sizeof(cycle));
        cycle.mOutputTime.mSampleTime = T;
        cycle.mCurrentTime.mSampleTime = T;

        st = (*ref)->BeginIOOperation(ref, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cycle);
        CHECK(st == 0, "BeginIOOperation(WriteMix)");
        st = (*ref)->DoIOOperation(ref, kObjectID_Device, kObjectID_Stream_Output, 1,
                                   kAudioServerPlugInIOOperationWriteMix, frames, &cycle, writeBuf, NULL);
        CHECK(st == 0, "DoIOOperation(WriteMix) accepts audio");
        st = (*ref)->EndIOOperation(ref, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix, frames, &cycle);
        CHECK(st == 0, "EndIOOperation(WriteMix)");

        // ...and read it back at input sample time T: the loopback contract.
        memset(&cycle, 0, sizeof(cycle));
        cycle.mInputTime.mSampleTime = T;
        cycle.mCurrentTime.mSampleTime = T + frames;
        st = (*ref)->DoIOOperation(ref, kObjectID_Device, kObjectID_Stream_Input, 1,
                                   kAudioServerPlugInIOOperationReadInput, frames, &cycle, readBuf, NULL);
        CHECK(st == 0, "DoIOOperation(ReadInput) returns audio");

        bool identical = memcmp(writeBuf, readBuf, samples * sizeof(Float32)) == 0;
        if (!identical) {
            // Diagnostic: how far apart are they?
            double maxDiff = 0;
            for (UInt32 i = 0; i < samples; i++) {
                double d = fabs((double)writeBuf[i] - (double)readBuf[i]);
                if (d > maxDiff) maxDiff = d;
            }
            printf("      (loopback mismatch, max sample difference %.6f)\n", maxDiff);
        }
        CHECK(identical, "loopback: audio read back is bit-identical to audio written");

        // Reading a range that was never written must return silence, not garbage.
        memset(&cycle, 0, sizeof(cycle));
        cycle.mInputTime.mSampleTime = T + 40000;
        st = (*ref)->DoIOOperation(ref, kObjectID_Device, kObjectID_Stream_Input, 1,
                                   kAudioServerPlugInIOOperationReadInput, frames, &cycle, readBuf, NULL);
        bool silent = st == 0;
        for (UInt32 i = 0; silent && i < samples; i++) silent = readBuf[i] == 0.0f;
        CHECK(silent, "reading an unwritten region returns silence");

        st = (*ref)->StopIO(ref, kObjectID_Device, 1);
        CHECK(st == 0, "StopIO");

        free(writeBuf); free(readBuf);
    }

    // 8. A second IO session must work after the first one closed.
    {
        st = (*ref)->StartIO(ref, kObjectID_Device, 2);
        OSStatus st2 = (*ref)->StopIO(ref, kObjectID_Device, 2);
        CHECK(st == 0 && st2 == 0, "IO can start and stop again after a completed session");
    }

    printf("\n== results: %d passed, %d failed ==\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
