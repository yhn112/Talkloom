# The command-line tools this project expects, so a fresh machine is one `brew bundle`
# away. Xcode itself is not here: it comes from the App Store and is a decision, not a
# dependency (AGENTS.md, "Missing a tool? Ask — don't route around it").
#
# swift-format is deliberately absent too — it ships inside Xcode and is reached through
# `xcrun`, so a Homebrew copy would only introduce a second version to disagree with.

# Generates Transcriber.xcodeproj from project.yml.
brew "xcodegen"
# Collapses xcodebuild output to the errors. Measured at 98 kB against 127 bytes for a
# green run, which is the difference between an agent reading the failure and not.
brew "xcsift"
# Audits the workflows for the failures that never turn CI red: an action pinned to a
# movable tag, a token left in .git/config, an expression that interpolates untrusted input.
brew "zizmor"
# The Python tooling for ASR evaluation and recording analysis lives in scripts/, beside the
# uv manifest that pins it.
brew "uv"
# Evaluation tooling only. The app itself uses afconvert, which ships with macOS, so that
# it acquires no Homebrew dependency it cannot satisfy on someone else's machine.
brew "ffmpeg"
