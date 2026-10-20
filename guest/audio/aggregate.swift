// aggregate — wire the macOS guest's audio loopback.
//
//   aggregate            create the aggregate if missing, make it the default
//   aggregate --check    exit 0 if it is already wired, 1 otherwise
//
// WHY THIS EXISTS
//
// easystream no longer creates audio devices: it only reads whatever the system
// default output is (a daemon restart must never rebuild the system's default
// output underneath running apps). The wiring therefore has to happen at boot,
// once, from oem.sh — which needs a standalone tool.
//
// The C version of this tool crashed inside CFDictionaryCreate (EXC_BAD_ACCESS)
// while building the aggregate description and died before it could print
// anything; with launchd's KeepAlive that became an oem.sh restart every 10 s
// and a guest running nothing but sshd. A plist-based version does not work
// either: com.apple.audio.AggregateDevices.plist is coreaudiod's OUTPUT, not an
// input — writing it is accepted and preserved but never instantiates a device.
//
// So this is Swift, doing exactly what easystream used to do (and what Audio MIDI
// Setup does): call AudioHardwareCreateAggregateDevice. The Swift toolchain gets
// the CoreFoundation bridging right, which is where the C version fell over.
//
// Build (on macOS):
//   swiftc -O -o aggregate aggregate.swift

import CoreAudio
import Foundation

let aggregateName = "easystream Audio"
let aggregateUID = "easystream-audio-aggregate"

func log(_ s: String) {
    FileHandle.standardError.write("aggregate: \(s)\n".data(using: .utf8)!)
}

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
        size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func deviceName(_ id: AudioObjectID) -> String {
    var name: CFString = "" as CFString
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr
    else { return "" }
    return name as String
}

func deviceUID(_ id: AudioObjectID) -> String {
    var uid: CFString = "" as CFString
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr
    else { return "" }
    return uid as String
}

/// channelCount reports the number of channels in `scope`, which is how the clock
/// source is chosen: a device with output channels can clock the aggregate. This
/// is a capability test, NOT a name match — a renamed sound card must not break
/// the audio path.
func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, abl) == noErr
    else { return 0 }
    var channels = 0
    for buf in UnsafeMutableAudioBufferListPointer(abl) {
        channels += Int(buf.mNumberChannels)
    }
    return channels
}

func setDefault(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = id
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
        UInt32(MemoryLayout<AudioObjectID>.size), &dev) == noErr
}

func defaultOutput() -> AudioObjectID {
    var dev = AudioObjectID(kAudioObjectUnknown)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
    else { return AudioObjectID(kAudioObjectUnknown) }
    return dev
}

let checkOnly = CommandLine.arguments.contains("--check")

let devices = allDevices()
guard !devices.isEmpty else {
    log("cannot enumerate CoreAudio devices")
    exit(1)
}

// Already built? Then only make sure it is the default output and stop: a boot
// must not churn the audio stack.
if let existing = devices.first(where: { deviceName($0) == aggregateName }) {
    if checkOnly {
        log("already present (id \(existing))")
        exit(0)
    }
    if defaultOutput() == existing {
        log("\"\(aggregateName)\" present and default; nothing to do")
        exit(0)
    }
    if setDefault(existing, kAudioHardwarePropertyDefaultOutputDevice),
       setDefault(existing, kAudioHardwarePropertyDefaultSystemOutputDevice) {
        log("\"\(aggregateName)\" present; default output re-pointed at it")
        exit(0)
    }
    log("cannot set the default output")
    exit(2)
}

if checkOnly {
    log("not wired")
    exit(1)
}

guard let blackhole = devices.first(where: { deviceName($0).contains("BlackHole") }) else {
    log("no BlackHole device (is the HAL plug-in installed?)")
    exit(1)
}
let bhUID = deviceUID(blackhole)
guard !bhUID.isEmpty else {
    log("BlackHole has no UID")
    exit(1)
}

guard let clock = devices.first(where: {
    $0 != blackhole && channelCount($0, scope: kAudioObjectPropertyScopeOutput) > 0
}) else {
    log("no real output device to clock the aggregate")
    exit(1)
}
let clockUID = deviceUID(clock)
guard !clockUID.isEmpty else {
    log("clock device \"\(deviceName(clock))\" has no UID")
    exit(1)
}
log("clock device = \"\(deviceName(clock))\"")

// BlackHole has no clock of its own: it is aggregated WITH the real output, which
// provides the clock, and the aggregate becomes the default output so every app's
// sound is routed into BlackHole for us to read back.
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: aggregateName,
    kAudioAggregateDeviceUIDKey as String: aggregateUID,
    kAudioAggregateDeviceIsPrivateKey as String: false,
    kAudioAggregateDeviceIsStackedKey as String: false,
    kAudioAggregateDeviceClockDeviceKey as String: clockUID,
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: bhUID]
    ],
]

var agg = AudioObjectID(kAudioObjectUnknown)
let rc = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
guard rc == noErr, agg != kAudioObjectUnknown else {
    log("AudioHardwareCreateAggregateDevice failed (\(rc))")
    exit(2)
}
log("created \"\(aggregateName)\" (id \(agg))")

guard setDefault(agg, kAudioHardwarePropertyDefaultOutputDevice),
      setDefault(agg, kAudioHardwarePropertyDefaultSystemOutputDevice) else {
    log("cannot set the default output to the aggregate")
    exit(2)
}
log("default output -> \"\(aggregateName)\"")
exit(0)
