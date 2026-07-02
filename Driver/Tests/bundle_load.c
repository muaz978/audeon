// Stage 0 bundle test for the Audeon virtual audio driver.
//
// Loads the built AudeonAudio.driver bundle through the real CFPlugIn
// machinery, which is how coreaudiod discovers and instantiates HAL plug-ins:
// read Info.plist, resolve the declared factory, create an instance, then
// talk to it through the AudioServerPlugIn interface. This validates the
// bundle packaging that the in-process harness cannot see.
//
// Runs entirely inside this process. Nothing is installed.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <stdio.h>
#include <string.h>

static int gPass = 0;
static int gFail = 0;

#define CHECK(cond, name) do { \
    if (cond) { gPass++; printf("PASS  %s\n", name); } \
    else      { gFail++; printf("FAIL  %s\n", name); } \
} while (0)

// Minimal fake host: the driver stores it at Initialize and may call it later.
static OSStatus FakePropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a) { (void)h;(void)o;(void)n;(void)a; return 0; }
static OSStatus FakeCopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef* out) { (void)h;(void)k; if (out) *out = NULL; return kAudioHardwareUnknownPropertyError; }
static OSStatus FakeWriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { (void)h;(void)k;(void)d; return 0; }
static OSStatus FakeDeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k) { (void)h;(void)k; return 0; }
static OSStatus FakeRequestChange(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 a, void* i) { (void)h;(void)d;(void)a;(void)i; return 0; }

static AudioServerPlugInHostInterface gFakeHost = {
    FakePropertiesChanged, FakeCopyFromStorage, FakeWriteToStorage, FakeDeleteFromStorage, FakeRequestChange,
};

int main(int argc, const char* argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: bundle_load <path to AudeonAudio.driver>\n"); return 2; }
    printf("== Audeon driver bundle load test ==\n\n");

    CFStringRef path = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, true);
    CFPlugInRef plugIn = CFPlugInCreate(NULL, url);
    CHECK(plugIn != NULL, "CFPlugInCreate loads the bundle");
    if (!plugIn) return 1;

    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugIn);
    CHECK(factories != NULL && CFArrayGetCount(factories) == 1,
          "Info.plist declares exactly one factory for the AudioServerPlugIn type");
    if (!factories || CFArrayGetCount(factories) < 1) return 1;

    CFUUIDRef factoryUUID = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);
    void* instance = CFPlugInInstanceCreate(NULL, factoryUUID, kAudioServerPlugInTypeUUID);
    CHECK(instance != NULL, "factory creates a driver instance");
    if (!instance) return 1;

    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)instance;
    void* iface = NULL;
    HRESULT hr = (*driver)->QueryInterface(driver, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface);
    CHECK(hr == 0 && iface != NULL, "QueryInterface(AudioServerPlugInDriverInterface)");

    OSStatus st = (*driver)->Initialize(driver, &gFakeHost);
    CHECK(st == 0, "Initialize");

    // Discover the device through the plug-in object, like a host would.
    AudioObjectPropertyAddress addr = { kAudioPlugInPropertyDeviceList,
                                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID devices[8] = {0};
    UInt32 outSize = 0;
    st = (*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &addr, 0, NULL, sizeof(devices), &outSize, devices);
    UInt32 deviceCount = outSize / sizeof(AudioObjectID);
    CHECK(st == 0 && deviceCount >= 1, "plug-in reports at least one device");

    if (deviceCount >= 1) {
        addr.mSelector = kAudioObjectPropertyName;
        CFStringRef name = NULL;
        st = (*driver)->GetPropertyData(driver, devices[0], 0, &addr, 0, NULL, sizeof(name), &outSize, &name);
        char buf[256] = {0};
        bool ok = st == 0 && name && CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)
                  && strcmp(buf, "Audeon Stream") == 0;
        if (!ok && name) printf("      (got \"%s\")\n", buf);
        CHECK(ok, "device from the loaded bundle is named \"Audeon Stream\"");
        if (name) CFRelease(name);
    }

    printf("\n== results: %d passed, %d failed ==\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
