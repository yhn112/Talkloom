# System audio capture via CoreAudio process taps

Verified against the Xcode 26.6 macOS SDK headers. Every claim below cites the header and
line it came from; re-check them rather than trusting this file if behaviour surprises you.

Header paths are relative to
`$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/`. Swift
overlay citations refer to
`$(xcrun --show-sdk-path)/usr/lib/swift/CoreAudio.swiftmodule/arm64e-apple-macos.swiftinterface`.

## Availability

The underlying `AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` are
`API_AVAILABLE(macos(14.2))` (`AudioHardwareTapping.h:44`, `:54`). Production code uses the
Swift lifecycle overlay instead: `AudioHardwareSystem` is available in macOS 15.0 and
provides throwing `make/destroyProcessTap` and `make/destroyAggregateDevice`
(`CoreAudio.swiftinterface:12`–`:15`, `:73`–`:76`). The project's floor is also 15.0, so no
availability branch is required.

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

`AudioHardwareTap.format` and `.uid` are throwing Swift getters
(`CoreAudio.swiftinterface:665`–`:675`). Read them **before** starting the device and
configure the aggregate and writer from what the created tap actually reports. Assuming a
format here is the mistake that produces a valid file full of silence. The raw selectors
above document the underlying HAL contract; production code does not query them manually.

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

`kAudioAggregateDeviceTapAutoStartKey` makes device start wait until a tapped process
actually produces audio. The header states it **requires the private key to also be set**
(`AudioHardware.h:1637`–`:1644`). This project sets it to **false**: waiting means the first
sample lands whenever something happens to play, leaving the beginning of the meeting
unaccounted for. Measured against a four-second recording that began 1.7 s before playback
started, auto-start produced a 2.35 s track; with it off, 3.99 s.

Create with `AudioHardwareSystem.makeAggregateDevice(description:)` and tear down with
`destroyAggregateDevice` (`CoreAudio.swiftinterface:73`–`:74`). Creation both throws and
returns an optional, so callers handle an error and a `nil` result independently. The
underlying destruction is asynchronous (`AudioHardware.h:670`–`:680`), and an aggregate
that is never explicitly destroyed outlives the process; releasing the Swift handle is not
documented as cleanup.

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

The Swift overlay has no IOProc create/destroy methods, so those two C calls remain. Once
the IOProc exists, `AudioHardwareDevice.start/stop(IOProcID:)` provide the throwing Swift
lifecycle (`CoreAudio.swiftinterface:558`–`:560`). Passing `nil` to `start` only starts the
hardware for timing services; it does not install a callback or deliver samples
(`AudioHardware.h:1421`–`:1442`).

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
controller. The controller restarts only that path; the other recorder continues. A
terminal event or exhausted retry budget leaves the failed path unavailable and visible to
the user instead of ending a still-usable session.

## A replacement producer always starts a new segment

Neither capture API documents callback quiescence at teardown. CoreAudio retains the
IOBlock and its dispatch queue until `AudioDeviceDestroyIOProcID`, but the declarations for
destroy and stop promise only to destroy the ID and stop IO; they do not promise that no
callback is already in flight (`AudioHardware.h:1382`–`:1419`, `:1463`–`:1474`). Likewise,
AVFAudio says a tap can be removed while its engine is running and that stopping releases
prepared resources, but neither `removeTapOnBus:` nor `stop` documents a callback barrier
(`AVAudioNode.h:96`–`:124`, `AVAudioEngine.h:378`–`:386`). A serial-queue barrier can drain
work already enqueued, but cannot prove that a producer will enqueue nothing afterwards.

Every replacement producer therefore owns a new `TrackInput`, ring buffer, recorder and
native-rate WAV, even when the sample rate did not change. Any late callback remains
isolated on the retired input and cannot corrupt the replacement segment. Files are named
`mic.wav`, `mic-2.wav`, … and `system.wav`, `system-2.wav`, …; `source` plus
`segmentIndex` in `session.json` group those physical masters into the two logical tracks.

The retired input's last accepted sample endpoint becomes frame zero of its replacement.
The replacement drops blocks until one carries a valid hardware host-time anchor, then
inserts native-rate silence from that endpoint to the new anchor before writing real
samples. The first real span independently records the new anchor and its frame offset.
This preserves the wall-clock gap in both the WAV and the manifest, including when the new
device reports a different native rate; appending directly would compress the meeting.

System capture is not considered restored until a new active verification signal reaches
the replacement tap. Until that succeeds, microphone echo cancellation cannot be trusted:
if verification fails, the microphone itself starts a new segment without Voice Processing
IO so speaker output remains available in the mixed microphone track.

### Voice Processing IO engines outlive microphone segments

AVAudioEngine's configuration-change notification runs on an internal dispatch queue, and
the header explicitly forbids deallocating the engine from its handler because synchronous
teardown can deadlock (`AVAudioEngine.h:871`–`:897`). No public remove, stop, reset or voice-
processing toggle API documents that the same internal property-listener queue is drained.
The header separately notes that two engine instances can be advantageous for dynamic I/O-
mode switching (`AVAudioEngine.h:451`–`:470`).

A Sony-headphone switch run reproduced the missing lifetime boundary. The tap itself
survived the default-output change, so the harness forced its real teardown/rebuild path.
The retired system segment was 15.4 s at peak 0.3179 with zero drops; the simultaneous
voice-processed microphone segment was 13.3 s at peak 0.1414 with zero drops. The restarted
system probe then caused the microphone's data-preserving fallback from voice processing to
raw capture. Releasing the stopped VPIO engine at that transition crashed with
`EXC_BAD_ACCESS` in `AVAudioIOUnit::IOUnitPropertyListener` on
`com.apple.coreaudio.AUVoiceProcessingIO`, before a replacement microphone segment could
start.

The same Sony switch protocol passed after the bounded-engine fix. The output switch
restarted the microphone naturally, while the tap-only aggregate survived and the harness
therefore forced the system path's real rebuild. All five segments reported zero drops:

| Segment | Native rate | Duration | Peak |
| --- | ---: | ---: | ---: |
| `mic.wav` (voice processed) | 48 kHz | 11.800 s | 0.0969 |
| `mic-2.wav` (voice processed) | 48 kHz | 2.011 s | 0.0013 |
| `mic-3.wav` (mixed fallback) | 16 kHz | 5.074 s | 0.0030 |
| `system.wav` | 48 kHz | 14.432 s | 0.3179 |
| `system-2.wav` | 48 kHz | 5.919 s | 0.3412 |

The replacement system master begins with 3,013 silent frames at 48 kHz, a measured gap
of 0.063 s, followed by non-silent speech. The system timeline began 1.309 s before the
microphone and their final logical endpoints were 20.351 s and 20.193 s, a 0.157 s
difference. The microphone's switch to a 16 kHz native device also confirms that a rate
change starts a new master instead of changing the existing WAV's format.

`MicrophoneCapture` therefore owns two stable engine graphs for its process-long lifetime:
one has VPIO enabled once and never disabled, and the other has never hosted VPIO. A
voice-processed-to-raw transition borrows the second graph without releasing or toggling
the first. Physical segments still receive new tap closures, inputs, recorders and WAVs, so
late sample callbacks stay isolated while AVFAudio's undocumented listener lifetime stays
valid.

## Call sequence

1. Build a `CATapDescription` (mono global, empty exclusion list); set `privateTap`.
2. `AudioHardwareSystem.shared.makeProcessTap` → `AudioHardwareTap`.
3. Read the tap's throwing `format` and `uid` properties.
4. Compose the aggregate dictionary: private, not stacked, an empty `"subdevices"` list,
   `"tapautostart"` false, and `"taps"` holding one entry keyed by `"uid"` with the
   created tap's returned UID plus `"drift"`.
5. `AudioHardwareSystem.shared.makeAggregateDevice` → `AudioHardwareAggregateDevice`.
6. `AudioDeviceCreateIOProcIDWithBlock`, then `aggregate.start(IOProcID:)`.
7. On teardown, reverse it: `aggregate.stop`, destroy the IOProcID with the remaining C
   API, then ask `AudioHardwareSystem` to destroy the aggregate and tap explicitly.

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
empty exclusion list: `AudioHardwareTap.format` returns 48000 Hz, 1 channel, 4 bytes per
frame, 1 frame per packet, flags `0x9` — that is `kAudioFormatFlagIsFloat |
kAudioFormatFlagIsPacked`, so packed interleaved Float32. Read it anyway rather than
assuming it; a device that reports something else will hand over exactly what it said.

## AudioCapture permission has no public status query

The public SDK exposes no authorization or health property for a process tap. The complete
tap property set is UID, description and format (`AudioHardware.h:1988`–`:2028`), while
tap creation, aggregate creation and device start expose the same HAL failures through an
untyped throwing Swift API; IOProc creation still returns a generic `OSStatus`. A successful
start therefore does not establish `kTCCServiceAudioCapture` access, and a stream of
zero-valued samples cannot be distinguished from legitimate silence.

`kAudioDevicePermissionsError` is generic and is not documented as a process-tap TCC
result. `kAudioHardwarePropertyProcessInputMute`,
`kAudioHardwarePropertyProcessIsAudible`, and
`kAudioProcessPropertyIsRunningOutput` describe the current process or its output IO;
none reports whether this process may read a tap. Screen-capture preflight checks a
different, heavier permission and is not a substitute.

The app therefore starts the tap before the microphone and has the system `afplay` process
play a short, low-level tone. A separate process matters: capturing the app's own output
would not prove that TCC lets it read the other processes which carry a remote meeting.
Only a new above-threshold sample after that probe is armed verifies the path; a lifetime
peak, successful API calls and arbitrary silence do not. The tone sits above the canonical
ASR format's passband, so offline conversion filters it out.

Verification gates microphone echo cancellation because cancellation removes speaker
output from the other available track. If the probe is absent or cannot be played, the
system capture remains open but the microphone starts without cancellation and is marked
as mixed. The manifest carries a warning. This is a data-preserving fallback, not a claim
that permission was denied: headphones can still make a mixed microphone local-only, and
a later system signal can still make the system file useful.

A single Voice Processing IO client cannot provide processed and raw microphone outputs
at once: its microphone bus is the processed uplink, input taps observe that output, and
bypass changes the same path globally. A separate raw client is expressible through the
public API but is not a portable fallback. In the built-in-device experiment, starting raw
then AEC left raw at 0.20 s / peak 0.0001 while AEC reached 3.00 s / 0.0065; reversing the
order produced raw at 4.00 s / 0.0109 and AEC at 3.10 s / 0.7577. The order-dependent
ownership is why the app uses an active system-path probe rather than two microphone
clients.
