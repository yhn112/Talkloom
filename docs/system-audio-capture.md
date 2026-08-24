# System audio capture via CoreAudio process taps

Verified against the Xcode 26.6 macOS SDK headers. Every claim below cites the header and
line it came from; re-check them rather than trusting this file if behaviour surprises you.

Paths are relative to
`$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/`.

## Availability

`AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` are
`API_AVAILABLE(macos(14.2))` (`AudioHardwareTapping.h:44`, `:54`). The project's floor is
15.0, set by `Synchronization.Atomic` rather than by tapping, so these are available
unconditionally.

`CATapDescription` gained `bundleIDs` and `processRestoreEnabled` in macOS 26.0
(`CATapDescription.h:136`, `:167`). Both describe which processes a tap follows, and this
app takes a global tap, so neither is a reason to raise the floor further.

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

Query `kAudioTapPropertyFormat` **before** starting the device and configure the writer from
what it actually reports. Assuming a format here is the mistake that produces a valid file
full of silence.

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

## Device changes are detected by their effect

Changing the default output device can tear down the aggregate, but a tap-only aggregate
does not necessarily die whenever the default changes. Listening to
`kAudioHardwarePropertyDefaultOutputDevice` therefore has both false positives and false
negatives. The implementation watches whether the tap continues delivering frames instead.

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
couple of seconds has stopped. That is the signal this project reports to the recording
controller. The controller finalizes both tracks and shows a failure; it does not append a
replacement stream to the same WAV because that would hide the gap from the timeline.

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

## Voice processing ducks what the tap records

The microphone runs through Voice Processing IO for echo cancellation, and voice processing
also ducks "other audio" so a chat stays intelligible. Other audio here is the meeting, and
the tap records the output mix *after* that ducking — so the setting on the microphone
determines how loud the remote participants land in the system track.

Measured with a 440 Hz tone at amplitude 0.5 played through the built-in speakers, RMS over
a settled window, against the same tone recorded with no microphone running (−9.0 dBFS,
which is exactly the theoretical RMS of that tone, so the tap itself is unity gain):

| `enableAdvancedDucking` | `duckingLevel` | Level | Attenuation |
| --- | --- | --- | --- |
| false | `.min` | −17.0 dBFS | **−8.0 dB** |
| false | `.mid` | −33.0 dBFS | −24.0 dB |
| false | `.default` | −39.0 dBFS | −30.0 dB |
| false | `.max` | −59.0 dBFS | −50.0 dB |
| true | `.min` | −24.9 dBFS | −15.9 dB |
| true | `.default` | −31.2 dBFS | −22.1 dB |
| true | `.mid` | −31.3 dBFS | −22.2 dB |
| true | `.max` | −36.3 dBFS | −27.3 dB |

Reproducible to 0.1 dB across runs. `false` + `.min` is the floor and is what the app uses;
note that Apple's WWDC23 sample pairs `.min` with advanced ducking *enabled*, which is right
for a call where other audio is a distraction and costs another 8 dB here.

Eight decibels is not nothing, but −17 dBFS is far above anything ASR struggles with, so it
is accepted rather than worked around. The alternative worth revisiting later is to drop
voice processing altogether and cancel the echo offline instead: both tracks are on disk
with a common time origin, so the reference signal the canceller needs is exactly the system
track.

### Measure a settled level, not a peak

Ducking ramps in rather than switching. A peak taken across the ramp reports whatever
fraction of the un-ducked opening happened to land in the window, and the same configuration
came back at 0.44 and at 0.199 on consecutive runs before this was noticed. Peak amplitude
answers "is this track silent", which is what the capture tests need; it does not answer
"how loud is it".

## What the tap reports

Measured on macOS 26.6, built-in output, `initMonoGlobalTapButExcludeProcesses` with an
empty exclusion list: `kAudioTapPropertyFormat` returns 48000 Hz, 1 channel, 4 bytes per
frame, 1 frame per packet, flags `0x9` — that is `kAudioFormatFlagIsFloat |
kAudioFormatFlagIsPacked`, so packed interleaved Float32. Read it anyway rather than
assuming it; a device that reports something else will hand over exactly what it said.

## AudioCapture permission has no public status query

The public SDK exposes no authorization or health property for a process tap. The complete
tap property set is UID, description and format (`AudioHardware.h:1988`–`:2028`), while
tap creation, aggregate creation, IOProc creation and device start return only a generic
`OSStatus`. A successful start therefore does not establish `kTCCServiceAudioCapture`
access, and a stream of zero-valued samples cannot be distinguished from legitimate
silence.

`kAudioDevicePermissionsError` is generic and is not documented as a process-tap TCC
result. `kAudioHardwarePropertyProcessInputMute`,
`kAudioHardwarePropertyProcessIsAudible`, and
`kAudioProcessPropertyIsRunningOutput` describe the current process or its output IO;
none reports whether this process may read a tap. Screen-capture preflight checks a
different, heavier permission and is not a substitute.

The app consequently reports system audio as verified only after it has actually recorded
a non-silent signal. Until then the state is unknown, not denied. This proves the capture
path worked on that recording; it is not a persistent authorization query.
