The build from the newest commit on `main`, replaced by the next one. Not a release in the
usual sense: this is a local meeting transcriber under development, it is not distributed, and
the app is therefore ad-hoc signed and deliberately not notarized.

Two consequences follow, and neither is a fault in the build.

**macOS will refuse to open it.** The disk image arrives quarantined. Drag the app into
Applications, then:

```bash
sudo xattr -dr com.apple.quarantine /Applications/Talkloom.app
```

**Permissions do not carry over from the build before.** macOS binds the microphone and
audio-capture grants to the app's signature, and every build here carries a different one, so
they have to be granted again under System Settings › Privacy & Security. The README's
Permissions section names the two and explains why exactly one of them missing is what a
single silent track looks like.
