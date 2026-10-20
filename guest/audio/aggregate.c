// aggregate — make the macOS audio-loopback aggregate exist and be the default.
//
// WHY THIS IS A SEPARATE TOOL (and not done inside easystream):
//
// The daemon used to create the aggregate device itself on every start, which
// meant it also had to *destroy* whatever was there first (a fixed UID cannot be
// re-created over an existing one). That made the audio path a side effect of
// the daemon: crash it, restart it, and the system's default output device
// changed underneath every app. It also had to guess the clock source by
// matching device NAME strings ("QEMU", "Audio Output"), which breaks the moment
// the VM's sound card names itself differently.
//
// Doing it here instead makes the guest's audio wiring a property of the GUEST,
// set up once at boot by oem.sh, and the daemon merely consumes it:
//   * idempotent — re-running is a no-op when the aggregate is already right;
//   * no destroy/recreate churn, so no window where the default output is
//     missing and apps are silent;
//   * the daemon no longer needs to know about clocks, aggregates or names.
//
// WHAT IT BUILDS
//
//   Aggregate "easystream Audio" (UID "easystream-audio-aggregate")
//     clock  : the machine's real output (QEMU USB sound card) — BlackHole has
//              no clock of its own and stays silent without one
//     member : BlackHole 2ch (the loopback the daemon reads)
//   then makes it the default OUTPUT and SYSTEM OUTPUT device, so every app's
//   sound is routed into BlackHole.
//
// Exit codes: 0 ok (created or already correct), 1 nothing usable found,
// 2 CoreAudio refused.
//
// Build:  clang -O2 -framework CoreAudio -framework CoreFoundation \
//               -o aggregate aggregate.c

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

static const char *kAggName = "easystream Audio";
static const char *kAggUID = "easystream-audio-aggregate";

static int fail(const char *msg, OSStatus st) {
  fprintf(stderr, "aggregate: %s (OSStatus %d)\n", msg, (int)st);
  return 2;
}

// devName copies a device's display name into buf (UTF-8).
static void devName(AudioObjectID dev, char *buf, size_t n) {
  buf[0] = '\0';
  CFStringRef s = NULL;
  UInt32 size = sizeof(s);
  AudioObjectPropertyAddress a = {kAudioObjectPropertyName,
                                  kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &s) != noErr || !s) return;
  CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
  CFRelease(s);
}

// devUID copies a device's UID (what an aggregate refers to) into buf.
static void devUID(AudioObjectID dev, char *buf, size_t n) {
  buf[0] = '\0';
  CFStringRef s = NULL;
  UInt32 size = sizeof(s);
  AudioObjectPropertyAddress a = {kAudioDevicePropertyDeviceUID,
                                  kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &s) != noErr || !s) return;
  CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
  CFRelease(s);
}

static int allDevices(AudioObjectID **out, UInt32 *count) {
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices,
                                  kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  OSStatus st = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
  if (st != noErr) return (int)st;
  UInt32 n = size / sizeof(AudioObjectID);
  AudioObjectID *ids = calloc(n ? n : 1, sizeof(AudioObjectID));
  if (!ids) return (int)kAudioHardwareUnspecifiedError;
  st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids);
  if (st != noErr) {
    free(ids);
    return (int)st;
  }
  *out = ids;
  *count = n;
  return 0;
}

static int setDefault(AudioObjectID dev, AudioObjectPropertySelector sel) {
  AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  return (int)AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL,
                                         sizeof(dev), &dev);
}

static AudioObjectID currentDefault(AudioObjectPropertySelector sel) {
  AudioObjectID dev = kAudioObjectUnknown;
  UInt32 size = sizeof(dev);
  AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) != noErr)
    return kAudioObjectUnknown;
  return dev;
}

int main(void) {
  AudioObjectID *devs = NULL;
  UInt32 n = 0;
  if (allDevices(&devs, &n) != 0) return fail("cannot enumerate devices", 0);

  AudioObjectID blackhole = kAudioObjectUnknown;
  AudioObjectID clock = kAudioObjectUnknown;
  AudioObjectID existing = kAudioObjectUnknown;
  char name[256], uid[512];

  for (UInt32 i = 0; i < n; i++) {
    devName(devs[i], name, sizeof(name));
    if (strstr(name, "BlackHole") && blackhole == kAudioObjectUnknown) blackhole = devs[i];
    if (strcmp(name, kAggName) == 0) existing = devs[i];
  }

  // The clock must be a REAL output device (BlackHole has no clock). Prefer an
  // output device that is not BlackHole and not our own aggregate.
  for (UInt32 i = 0; i < n; i++) {
    if (devs[i] == blackhole || devs[i] == existing) continue;
    UInt32 outs = 0, size = sizeof(outs);
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration,
                                    kAudioObjectPropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyDataSize(devs[i], &a, 0, NULL, &size) != noErr || size == 0) continue;
    AudioBufferList *bl = malloc(size);
    if (!bl) continue;
    if (AudioObjectGetPropertyData(devs[i], &a, 0, NULL, &size, bl) == noErr) {
      for (UInt32 b = 0; b < bl->mNumberBuffers; b++) outs += bl->mBuffers[b].mNumberChannels;
    }
    free(bl);
    if (outs > 0) {
      clock = devs[i];
      devName(clock, name, sizeof(name));
      printf("aggregate: clock device = \"%s\"\n", name);
      break;
    }
  }
  free(devs);

  if (blackhole == kAudioObjectUnknown) {
    fprintf(stderr, "aggregate: no BlackHole device (is the HAL plug-in installed?)\n");
    return 1;
  }
  if (clock == kAudioObjectUnknown) {
    fprintf(stderr, "aggregate: no real output device to clock the aggregate\n");
    return 1;
  }

  if (existing != kAudioObjectUnknown) {
    // Already built. Only the default-output routing can have drifted.
    AudioObjectID cur = currentDefault(kAudioHardwarePropertyDefaultOutputDevice);
    if (cur == existing) {
      printf("aggregate: \"%s\" already present and default; nothing to do\n", kAggName);
      return 0;
    }
    printf("aggregate: \"%s\" present; re-pointing default output at it\n", kAggName);
    if (setDefault(existing, kAudioHardwarePropertyDefaultOutputDevice) != 0 ||
        setDefault(existing, kAudioHardwarePropertyDefaultSystemOutputDevice) != 0)
      return fail("cannot set default output", 0);
    return 0;
  }

  if (AudioDeviceStart(clock, NULL) != noErr) return fail("cannot start clock device", 0);

  devUID(clock, uid, sizeof(uid));
  CFStringRef clockUID = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
  devUID(blackhole, uid, sizeof(uid));
  CFStringRef bhUID = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
  CFStringRef aggName = CFStringCreateWithCString(NULL, kAggName, kCFStringEncodingUTF8);
  CFStringRef aggUID = CFStringCreateWithCString(NULL, kAggUID, kCFStringEncodingUTF8);
  CFStringRef subUIDKey = CFSTR("uid");

  // One sub-device (BlackHole); the clock is a property of the aggregate, not a
  // member, so it is NOT in the sub-device list.
  CFTypeRef subList[] = {CFDictionaryCreate(NULL, (const void **)&subUIDKey,
                                            (const void **)&bhUID, 1,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks)};
  CFArrayRef subs = CFArrayCreate(NULL, subList, 1, &kCFTypeArrayCallBacks);

  const void *keys[] = {kAudioAggregateDeviceNameKey, kAudioAggregateDeviceUIDKey,
                        kAudioAggregateDeviceIsPrivateKey,
                        kAudioAggregateDeviceIsStackedKey,
                        kAudioAggregateDeviceClockDeviceKey,
                        kAudioAggregateDeviceSubDeviceListKey};
  const void *vals[] = {aggName, aggUID, kCFBooleanFalse, kCFBooleanFalse, clockUID, subs};
  CFDictionaryRef desc = CFDictionaryCreate(NULL, keys, vals, 6,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);

  AudioObjectID agg = kAudioObjectUnknown;
  OSStatus st = AudioHardwareCreateAggregateDevice(desc, &agg);
  if (st != noErr || agg == kAudioObjectUnknown)
    return fail("AudioHardwareCreateAggregateDevice failed", st);

  printf("aggregate: created \"%s\" (id %u)\n", kAggName, (unsigned)agg);

  // Making it the default is what actually routes app audio into BlackHole.
  int rc1 = setDefault(agg, kAudioHardwarePropertyDefaultOutputDevice);
  int rc2 = setDefault(agg, kAudioHardwarePropertyDefaultSystemOutputDevice);
  if (rc1 != 0 || rc2 != 0) return fail("cannot set default output", rc1 ? rc1 : rc2);

  if (AudioDeviceStart(agg, NULL) != noErr) return fail("cannot start the aggregate", 0);

  printf("aggregate: default output -> \"%s\"\n", kAggName);
  return 0;
}
