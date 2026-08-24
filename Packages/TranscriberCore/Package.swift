// swift-tools-version: 6.2
// 6.2 rather than 6.0 for `treatAllWarnings(as: .error)`, which is how project.yml's
// SWIFT_TREAT_WARNINGS_AS_ERRORS reaches this half of the code. The toolchain in use is
// 6.3, and the project already requires Xcode 26.
import PackageDescription

// The part of the app that needs neither a microphone nor a signed bundle: the WAV
// writer, the mach-time conversion, and the session manifest.
//
// It is a package so that `swift test` can run those tests without xcodebuild, without
// signing, and without a test host. Everything that touches CoreAudio, AVFoundation, TCC
// or the UI stays in the app target, where it can only be verified by building and
// recording anyway.
//
// The ring buffer deliberately stayed behind. It is the one type an audio callback calls
// directly, Swift does not inline across module boundaries by default, and the real-time
// path is not where a boundary should be paid for.
let package = Package(
    name: "TranscriberCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"])
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            swiftSettings: [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"],
            swiftSettings: [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]
        ),
    ]
)
