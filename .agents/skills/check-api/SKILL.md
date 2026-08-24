---
name: check-api
description: Verify a macOS system API's signature, availability, and semantics against the SDK headers before writing code. Use before first use of an unfamiliar CoreAudio, ScreenCaptureKit, AVFoundation, or Speech symbol, and when an API behaves unexpectedly. Do not use for searching this project's own code.
---

# Checking a system API against the headers

CoreAudio process taps, aggregate devices, and Voice Processing IO are barely covered by
public examples — but they are documented generously in header comments. A call written
from memory here usually compiles and then quietly does nothing: the constant exists but
means something else, or the callback arrives on a different thread. The cost of being
wrong is hours spent debugging silence in a recording, which makes checking cheaper than
guessing.

## Steps

1. **Find the symbol in the headers:**

   ```bash
   SDK=$(xcrun --show-sdk-path)
   grep -rn "AudioHardwareCreateProcessTap" "$SDK/System/Library/Frameworks/CoreAudio.framework/Headers/"
   ```

   If you don't know the framework, search all of them:
   `grep -rln "SymbolOrConstant" "$SDK/System/Library/Frameworks/"`

2. **Read the full doc comment, not the declaration line.** In the CoreAudio headers, the
   description of parameters, buffer ownership, and calling thread lives in the comment
   above the function — that is where the answers autocomplete can't give you are.

3. **Check availability verbatim against `API_AVAILABLE`.** This project's floor is
   macOS 14.2. A symbol introduced later needs `if #available` and a fallback path.

4. **For a Swift wrapper over Objective-C, confirm the actual imported signature** when
   it isn't obvious:

   ```bash
   swift-api-digester -dump-sdk -module CoreAudio -o /tmp/coreaudio.json 2>/dev/null
   ```

## What to establish per symbol

- Exact signature: parameters, return type, and how failure is reported (`OSStatus`,
  `throws`, `nil`, a delegate).
- Availability, quoted from the header.
- Memory ownership: who allocates and who releases buffers and handles.
- Calling thread: if the callback arrives on the audio thread, the ban on allocation and
  locking from `AGENTS.md` applies to it.
- Environment requirements: TCC permission, `Info.plist` key, entitlement, sandbox
  compatibility.

## Rules

The SDK headers are the primary source. Apple documentation, WWDC sessions, and GitHub
code are secondary and useful when a header is silent on semantics; mark such findings as
external.

If there is no confirmation, say so. "Not found, needs an experiment" is a valid answer;
a plausible reconstruction of a constant that doesn't exist is not.

## What to report

Confirmed facts with header file and line number, unconfirmed assumptions as a separate
list, and a conclusion: whether the API fits the purpose it was checked for, and what
constraints it imposes on the calling code.
