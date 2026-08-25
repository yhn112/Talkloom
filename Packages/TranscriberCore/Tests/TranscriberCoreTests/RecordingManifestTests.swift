import Foundation
import Testing
import TranscriberCore

@Suite("Recording manifest")
struct RecordingManifestTests {
    private func report(
        _ label: String,
        hostTime: UInt64?,
        frameCount: Int = 48_000,
        content: TrackContent = .local
    ) -> TrackReport {
        TrackReport(
            file: "\(label).wav",
            source: label == "mic" ? .microphone : .systemAudio,
            segmentIndex: 0,
            content: content,
            sampleRate: 48_000,
            frameCount: frameCount,
            peakAmplitude: 0.5,
            droppedSampleCount: 0,
            firstSampleHostTime: hostTime
        )
    }

    private func report(
        _ label: String,
        frameCount: Int,
        spans: [TrackReport.Span]
    ) -> TrackReport {
        TrackReport(
            file: "\(label).wav",
            source: .systemAudio,
            segmentIndex: 0,
            content: .remote,
            sampleRate: 48_000,
            frameCount: frameCount,
            peakAmplitude: 0.5,
            droppedSampleCount: frameCount - spans.reduce(0) { $0 + $1.frameCount },
            spans: spans,
            firstSampleHostTime: spans.first?.startHostTime
        )
    }

    /// Writes the manifest to a fresh directory, reads it back, and hands over what the
    /// file actually said — which is the only version that matters months later.
    private func roundTrip(_ manifest: RecordingManifest) throws -> RecordingManifest {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "Manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try manifest.write(to: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appending(path: RecordingManifest.fileName))
        return try decoder.decode(RecordingManifest.self, from: data)
    }

    /// The offset is the whole reason the manifest exists: the tracks do not start
    /// together, and nothing in the audio says by how much.
    @Test("offsets are relative to whichever track started first")
    func offsetsAreRelativeToTheEarliestTrack() throws {
        let second = HostTime.hostTicks(forSeconds: 0.75)
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [
                report("mic", hostTime: 1_000 + second),
                report("system", hostTime: 1_000),
            ]
        )
        #expect(manifest.status == .completed)

        let mic = try #require(manifest.tracks.first { $0.file == "mic.wav" })
        let system = try #require(manifest.tracks.first { $0.file == "system.wav" })
        #expect(system.startOffset == 0, "the earliest track defines the origin")
        #expect(abs(try #require(mic.startOffset) - 0.75) < 0.001)
    }

    /// A track that never received a sample cannot be aligned, and must not drag the
    /// origin somewhere arbitrary.
    @Test("a track that never started gets no offset")
    func aTrackThatNeverStartedGetsNoOffset() throws {
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [report("mic", hostTime: 5_000), report("system", hostTime: nil)]
        )
        #expect(manifest.status == .completed)

        let system = try #require(manifest.tracks.first { $0.file == "system.wav" })
        #expect(system.startOffset == nil)
        #expect(try #require(manifest.tracks.first { $0.file == "mic.wav" }).startOffset == 0)
    }

    /// The master contains the silence, while the spans say which frames came from the
    /// source and where each uninterrupted run belongs on the common hardware clock.
    @Test("anchored spans make an inserted gap explicit")
    func anchoredSpansMakeAnInsertedGapExplicit() throws {
        let origin: UInt64 = 1_000
        let second = HostTime.hostTicks(forSeconds: 1)
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [
                report(
                    "system",
                    frameCount: 120_000,
                    spans: [
                        .init(fileFrameOffset: 0, frameCount: 48_000, startHostTime: origin),
                        .init(
                            fileFrameOffset: 72_000,
                            frameCount: 48_000,
                            startHostTime: origin + second + second / 2
                        ),
                    ]
                )
            ]
        )

        let track = try #require(manifest.tracks.first)
        #expect(track.spans?.count == 2)
        #expect(track.startOffset == 0)
        #expect(track.spans?[0].startOffset == 0)
        #expect(abs(try #require(track.spans?[1].startOffset) - 1.5) < 0.001)
        #expect(track.gaps?.count == 1)
        #expect(track.gaps?.first?.fileFrameOffset == 48_000)
        #expect(track.gaps?.first?.frameCount == 24_000)
        #expect(track.gaps?.first?.duration == 0.5)
        #expect(try roundTrip(manifest) == manifest)
    }

    @Test("an initial dropped block precedes the first real span")
    func anInitialDroppedBlockPrecedesTheFirstRealSpan() throws {
        let origin: UInt64 = 1_000
        let halfSecond = HostTime.hostTicks(forSeconds: 0.5)
        let report = TrackReport(
            file: "system.wav",
            content: .remote,
            sampleRate: 48_000,
            frameCount: 72_000,
            peakAmplitude: 0.5,
            droppedSampleCount: 24_000,
            spans: [
                .init(
                    fileFrameOffset: 24_000,
                    frameCount: 48_000,
                    startHostTime: origin + halfSecond)
            ],
            firstSampleHostTime: origin
        )

        let track = try #require(
            RecordingManifest(
                startedAt: Date(timeIntervalSince1970: 0), reports: [report]
            ).tracks.first)

        #expect(track.startOffset == 0)
        #expect(abs(try #require(track.spans?.first?.startOffset) - 0.5) < 0.001)
        #expect(track.gaps?.first?.fileFrameOffset == 0)
        #expect(track.gaps?.first?.frameCount == 24_000)
    }

    @Test("native-rate segments remain one logical track")
    func nativeRateSegmentsRemainOneLogicalTrack() throws {
        let origin: UInt64 = 1_000
        let firstEnd = origin + HostTime.hostTicks(forSeconds: 1)
        let resumedAt = firstEnd + HostTime.hostTicks(forSeconds: 0.5)
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [
                TrackReport(
                    file: "system-2.wav",
                    source: .systemAudio,
                    segmentIndex: 1,
                    content: .remote,
                    sampleRate: 44_100,
                    frameCount: 66_150,
                    peakAmplitude: 0.4,
                    droppedSampleCount: 0,
                    spans: [
                        .init(
                            fileFrameOffset: 22_050,
                            frameCount: 44_100,
                            startHostTime: resumedAt)
                    ],
                    firstSampleHostTime: firstEnd
                ),
                TrackReport(
                    file: "system.wav",
                    source: .systemAudio,
                    segmentIndex: 0,
                    content: .remote,
                    sampleRate: 48_000,
                    frameCount: 48_000,
                    peakAmplitude: 0.5,
                    droppedSampleCount: 0,
                    firstSampleHostTime: origin
                ),
            ]
        )

        let segments = manifest.segments(for: .systemAudio)
        #expect(segments.map(\.file) == ["system.wav", "system-2.wav"])
        #expect(segments.map(\.sampleRate) == [48_000, 44_100])
        #expect(segments[1].startOffset == 1)
        #expect(abs(try #require(segments[1].spans?.first?.startOffset) - 1.5) < 0.001)
        #expect(segments[1].gaps?.first?.frameCount == 22_050)
        #expect(segments[1].gaps?.first?.duration == 0.5)
        #expect(try roundTrip(manifest) == manifest)
    }

    @Test("it round trips through the file it writes")
    func itRoundTripsThroughTheFileItWrites() throws {
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reports: [report("mic", hostTime: 1_000), report("system", hostTime: 1_000)],
            failure: "capture stopped"
        )
        #expect(manifest.status == .failed)

        #expect(try roundTrip(manifest) == manifest)
    }

    /// Finalization is too late to be the first durable copy: a killed process never runs
    /// it. The in-progress manifest therefore carries the raw host times until they can be
    /// replaced by portable offsets in the finished shape.
    @Test("first samples are checkpointed once while recording")
    func firstSamplesAreCheckpointedOnceWhileRecording() throws {
        let manifest = RecordingManifest.recording(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        .checkpointingFirstSample(file: "system.wav", hostTime: 1_000)
        .checkpointingFirstSample(file: "mic.wav", hostTime: 2_000)
        .checkpointingFirstSample(file: "system.wav", hostTime: 9_000)

        let decoded = try roundTrip(manifest)

        #expect(decoded.status == .recording)
        #expect(
            decoded.trackStarts == [
                .init(file: "mic.wav", hostTime: 2_000),
                .init(file: "system.wav", hostTime: 1_000),
            ])
    }

    /// The fallback recording is the one that must not be taken at face value later: echo
    /// cancellation is off, so the microphone track holds both sides of the call and cannot
    /// be labelled "me". The manifest is the only place that survives to say so.
    @Test("a mixed track and the reason for it are both persisted")
    func aMixedTrackAndItsReasonArePersisted() throws {
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reports: [report("mic", hostTime: 1_000, content: .mixed)],
            warning: "the system audio tap did not start"
        )

        let decoded = try roundTrip(manifest)

        #expect(decoded.status == .completed, "a degraded session still completed")
        #expect(decoded.warning == "the system audio tap did not start")
        #expect(decoded.tracks.first?.content == .mixed)
    }

    @Test("each capture path declares who is on its track")
    func eachCapturePathDeclaresWhoIsOnItsTrack() {
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [
                report("mic", hostTime: 1_000, content: .local),
                report("system", hostTime: 1_000, content: .remote),
            ]
        )

        #expect(manifest.tracks.first { $0.file == "mic.wav" }?.content == .local)
        #expect(manifest.tracks.first { $0.file == "system.wav" }?.content == .remote)
        #expect(manifest.warning == nil)
    }

    /// Recordings made before a field existed do not get a guess. Nothing in a finished file
    /// says whether echo cancellation was applied to it, and a manifest without a status
    /// describes a session that was finalized — the two legacy shapes are decoded, not
    /// repaired.
    @Test(
        "a legacy manifest decodes without guessing",
        arguments: [
            LegacyManifest(
                name: "no content on the track",
                json: """
                    {
                      "startedAt": "2023-11-14T22:13:20Z",
                      "status": "completed",
                      "tracks": [
                        {
                          "file": "mic.wav",
                          "sampleRate": 48000,
                          "frameCount": 48000,
                          "peakAmplitude": 0.5,
                          "droppedSampleCount": 0
                        }
                      ]
                    }
                    """,
                status: .completed,
                trackCount: 1,
                failure: nil
            ),
            LegacyManifest(
                name: "no status, no failure",
                json: """
                    {
                      "startedAt": "2023-11-14T22:13:20Z",
                      "tracks": []
                    }
                    """,
                status: .completed,
                trackCount: 0,
                failure: nil
            ),
            LegacyManifest(
                name: "no status, but a failure",
                json: """
                    {
                      "startedAt": "2023-11-14T22:13:20Z",
                      "tracks": [],
                      "failure": "capture stopped"
                    }
                    """,
                status: .failed,
                trackCount: 0,
                failure: "capture stopped"
            ),
        ]
    )
    func legacyManifestDecodes(_ legacy: LegacyManifest) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(RecordingManifest.self, from: Data(legacy.json.utf8))

        #expect(manifest.status == legacy.status)
        #expect(manifest.tracks.count == legacy.trackCount)
        #expect(manifest.failure == legacy.failure)
        #expect(manifest.warning == nil)
        #expect(manifest.trackStarts.isEmpty)
        #expect(manifest.tracks.allSatisfy { $0.content == nil })
        #expect(manifest.tracks.allSatisfy { $0.spans == nil })
        #expect(manifest.tracks.allSatisfy { $0.gaps == nil })
    }

    @Test("a legacy start offset becomes one continuous span")
    func aLegacyStartOffsetBecomesOneContinuousSpan() throws {
        let json = """
            {
              "startedAt": "2023-11-14T22:13:20Z",
              "status": "completed",
              "tracks": [
                {
                  "file": "mic.wav",
                  "sampleRate": 48000,
                  "frameCount": 48000,
                  "startOffset": 0.75
                }
              ]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(RecordingManifest.self, from: Data(json.utf8))
        let track = try #require(manifest.tracks.first)

        #expect(track.startOffset == 0.75)
        #expect(
            track.spans == [
                .init(startOffset: 0.75, fileFrameOffset: 0, frameCount: 48_000)
            ])
        #expect(track.gaps?.isEmpty == true)
    }

    /// A manifest shape written by an older version of the app.
    struct LegacyManifest: Sendable, CustomTestStringConvertible {
        let name: String
        let json: String
        let status: RecordingManifest.Status
        let trackCount: Int
        let failure: String?

        var testDescription: String { name }
    }
}
