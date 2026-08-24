# System audio capture via CoreAudio process taps

Verified against the Xcode 26.6 macOS SDK headers. Every claim below cites the header and
line it came from; re-check them rather than trusting this file if behaviour surprises you.

Paths are relative to
`$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/`.

## Availability

`AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` are
`API_AVAILABLE(macos(14.2))` (`AudioHardwareTapping.h:44`, `:54`). This is what sets the
project's deployment floor.

`CATapDescription` itself is `API_AVAILABLE(macos(12.0))` (`CATapDescription.h:44`), so the
class predates the functions that consume it — availability must be checked against the
functions, not the class.

Two members are macOS 26 only and must not be used at our floor: `bundleIDs` and
`processRestoreEnabled` (`CATapDescription.h`, both marked `API_AVAILABLE(macos(26.0))`).

## Describing the tap

`CATapDescription` offers four global/mixdown initializers plus two device-scoped ones
(`CATapDescription.h:47`–`:110`). The relevant one here:

```objc
- (instancetype)initMonoGlobalTapButExcludeProcesses:(NSArray<NSNumber*>*)processesToExclude;
```

It mixes every process that outputs audio, minus the excluded ones, down to **mono**.
Passing an empty array taps all system output. That matches the project's canonical ASR
format directly, so no downmix step is needed on our side — the stereo variant
(`initStereoGlobalTapButExcludeProcesses:`) would only add work.

All initializers are `NS_REFINED_FOR_SWIFT`, so Swift sees renamed signatures; confirm the
imported names before use rather than assuming the Objective-C spelling.

Properties worth knowing (`CATapDescription.h:112`–`:186`): `UUID` (the tap's identity,
needed to reference it from the aggregate device), `mono`, `exclusive`, `mixdown`,
`privateTap` (getter `isPrivate`), `muteBehavior`, `deviceUID`, and `stream`.

To build an exclusion list, enumerate processes with
`kAudioHardwarePropertyProcessObjectList` (`AudioHardware.h:633`) and identify them via
`kAudioProcessPropertyBundleID` (`AudioHardware.h:1979`).

## Reading the tap's format

The tap object answers three properties (`AudioHardware.h:2025`–`:2027`):

| Selector | Value |
| --- | --- |
| `kAudioTapPropertyUID` | `'tuid'` |
| `kAudioTapPropertyDescription` | `'tdsc'` |
| `kAudioTapPropertyFormat` | `'tfmt'` |

Query `kAudioTapPropertyFormat` **before** starting the device and configure the converter
from what it actually reports. Assuming a format here is the mistake that produces a valid
file full of silence.

## The aggregate device

A tap produces no audio by itself; it must be wrapped in an aggregate device. Keys and
their literal string values:

| Constant | Value | Header |
| --- | --- | --- |
| `kAudioAggregateDeviceUIDKey` | `"uid"` | `AudioHardware.h:1566` |
| `kAudioAggregateDeviceNameKey` | `"name"` | `:1574` |
| `kAudioAggregateDeviceSubDeviceListKey` | `"subdevices"` | `:1583` |
| `kAudioAggregateDeviceIsPrivateKey` | `"private"` | `:1614` |
| `kAudioAggregateDeviceTapListKey` | `"taps"` | `:1632` |
| `kAudioAggregateDeviceTapAutoStartKey` | `"tapautostart"` | `:1645` |
| `kAudioSubTapUIDKey` | `"uid"` | `:1866` |

Note that `kAudioSubTapUIDKey` and `kAudioSubDeviceUIDKey` are both `"uid"`; they are
distinguished by which list the dictionary sits in, not by the key itself.

`kAudioAggregateDeviceTapAutoStartKey` makes `AudioDeviceStart` wait until a tapped process
actually produces audio. The header states it **requires the private key to also be set**
(`AudioHardware.h:1637`–`:1644`). This project sets it to **false**: waiting means the first
sample lands whenever something happens to play, leaving the beginning of the meeting
unaccounted for. Measured against a four-second recording that began 1.7 s before playback
started, auto-start produced a 2.35 s track; with it off, 3.99 s.

Create with `AudioHardwareCreateAggregateDevice(CFDictionaryRef, AudioObjectID*)`
(`AudioHardware.h:667`) and tear down with `AudioHardwareDestroyAggregateDevice`
(`:680`). An aggregate that is never destroyed outlives the process.

## Receiving audio

```objc
OSStatus AudioDeviceCreateIOProcIDWithBlock(
    AudioDeviceIOProcID *outIOProcID,
    AudioObjectID        inDevice,
    dispatch_queue_t     inDispatchQueue,   // NULL => block invoked directly
    AudioDeviceIOBlock   inIOBlock);
```

`AudioHardware.h:1401`. The header is explicit that **all IOBlocks are dispatched
synchronously** onto the given queue, and that a NULL queue means direct invocation. Either
way the block runs under the real-time contract in `AGENTS.md`: copy into the ring buffer
and return. The queue does not make it safe to allocate or lock.

The dispatch queue and the block are both retained until a matching
`AudioDeviceDestroyIOProcID`.

## Rebuilding after a device change

Listen for `kAudioHardwarePropertyDefaultOutputDevice` (`'dOut'`, `AudioHardware.h:610`) on
the system object, with scope `kAudioObjectPropertyScopeGlobal` (`'glob'`,
`AudioHardwareBase.h:203`) and element `kAudioObjectPropertyElementMain` (`0`,
`AudioHardwareBase.h:207`). Plugging in headphones changes the default output and tears
down the aggregate, so the tap has to be rebuilt in response.

## The aggregate holds the tap and nothing else

Published examples, Apple's included, also list the current default output device as
`kAudioAggregateDeviceMainSubDeviceKey` and as the single entry of
`kAudioAggregateDeviceSubDeviceListKey`, to give the aggregate a time source. That works,
and it costs more than it gives.

An aggregate built that way carries the output device's own input stream as well as the
tap's, and the IO block then receives a buffer list with more than one buffer — with no
reliable way to tell from the list which buffer is the tap. Measured on this machine, with
Voice Processing IO active on the microphone at the same time:

| Aggregate | Buffer list delivered |
| --- | --- |
| tap + default output device, no voice processing | 1 buffer, 1 channel, 2048 bytes |
| tap + default output device, voice processing on | 2 buffers, **first has 6 channels**, 12288 bytes |
| tap alone | 1 buffer, 1 channel, 2048 bytes |

Reading the two-buffer case as a single stream — the obvious reading, since the tap is
mono — scaled the track's length by six and filled it with the output device's audio
instead of the tap's. Nothing reported an error: the file was valid, the sample rate was
right, and only its duration gave it away.

With no sub-device the list is always one buffer, and it is the tap. The aggregate also
stops depending on the default output device, which is what made the published recipe
fragile when headphones were plugged in.

## A tap that dies reports nothing

The documented failure is that changing the default output device tears the aggregate
down. Listening for `kAudioHardwarePropertyDefaultOutputDevice` addresses that one cause
and no other, and it forces a rebuild — a gap in the recording — every time the device
changes, whether or not the tap was affected.

Watching the tap's own output covers every cause and costs nothing. With auto-start off the
tap delivers frames continuously, silence included, so a stream that produces nothing for a
couple of seconds has stopped. That is the signal this project rebuilds on.

## Call sequence

1. Build a `CATapDescription` (mono global, empty exclusion list); set `privateTap`.
2. `AudioHardwareCreateProcessTap` → tap `AudioObjectID`.
3. Read `kAudioTapPropertyFormat` from the tap.
4. Compose the aggregate dictionary: private, not stacked, an empty `"subdevices"` list,
   `"tapautostart"` false, and `"taps"` holding one entry keyed by `"uid"` with the
   description's `UUID` string plus `"drift"`.
5. `AudioHardwareCreateAggregateDevice`.
6. `AudioDeviceCreateIOProcIDWithBlock`, then `AudioDeviceStart`.
7. On teardown, reverse it: stop, destroy the IOProcID, destroy the aggregate, destroy the tap.

## What the tap reports

Measured on macOS 26.6, built-in output, `initMonoGlobalTapButExcludeProcesses` with an
empty exclusion list: `kAudioTapPropertyFormat` returns 48000 Hz, 1 channel, 4 bytes per
frame, 1 frame per packet, flags `0x9` — that is `kAudioFormatFlagIsFloat |
kAudioFormatFlagIsPacked`, so packed interleaved Float32. Read it anyway rather than
assuming it; a device that reports something else will hand over exactly what it said.

## Not confirmed from headers

The headers say nothing about TCC. The permission is expected to be
`kTCCServiceAudioCapture` with `NSAudioCaptureUsageDescription` in `Info.plist`. A signed
build does record system audio successfully, so the path works end to end, but what happens
when the grant is *absent* has not been exercised here — whether the tap fails to create or
quietly produces silence is still unverified, and the error message assumes the former.
