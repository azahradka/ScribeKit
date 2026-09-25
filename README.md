# ScribeKit

Local speech-to-text with speakers for Swift. ScribeKit wraps [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Parakeet TDT v3 and offline diarization in a small API that returns a transcript with who said what, and renders it as
Markdown, plain text, SRT, WebVTT or JSON.

Everything runs on the Apple Neural Engine. No server, no API key, no Python.

- 25 European languages, automatic language detection
- Speaker diarization, or two-track "conversation" mode for calls (you on the microphone, everyone else on system audio)
- Echo removal: words the microphone picked up from the speakers are dropped
- Word timings, segments split on pauses and speaker turns
- Pure-Swift segment builder and renderers you can use with any ASR

Documentation: **[scribekit.lucaspiera.com](https://scribekit.lucaspiera.com)**

Used by [EchoPad](https://github.com/pieralukasz/echopad).

## Requirements

macOS 14 or iOS 17, Swift 6. Models (about 460 MB for speech, 20 MB for diarization) are downloaded from Hugging Face on
first use and cached in `~/Library/Application Support/FluidAudio`.

## Install

```swift
.package(url: "https://github.com/pieralukasz/ScribeKit.git", from: "0.1.0")
```

## Use

```swift
import ScribeKit

let scribe = Scribe.shared
try await scribe.prepare(diarization: true)          // optional: download and load ahead of time

// One file, speakers detected automatically
let transcript = try await scribe.transcribe(url, options: .init(language: "pl"))
for segment in transcript.segments {
    print(transcript.speaker(for: segment.speakerID)?.name ?? "", segment.text)
}

// A call recorded as two aligned tracks (see SystemAudioKit)
let call = try await scribe.transcribeConversation(
    microphone: micURL, system: systemURL,
    options: .init(localSpeakerName: "Łukasz"))

// Output
let markdown = TranscriptRenderer.markdown(call, options: .init(title: "Weekly sync"))
let subtitles = try TranscriptRenderer.render(call, as: .srt)
```

Plain text only:

```swift
let text = try await scribe.transcribeText(url)
```

## Command line

```bash
swift run -c release scribe prepare --diarize
swift run -c release scribe meeting.m4a --lang en --format md
swift run -c release scribe conversation mic.wav system.wav --me "Łukasz"
```

## License

MIT. The models are released by NVIDIA (Parakeet, CC-BY-4.0) and pyannote (diarization) and converted to Core ML by
FluidInference; check their licenses before shipping.
