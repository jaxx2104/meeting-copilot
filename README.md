# Meeting Copilot

A macOS app that listens to a meeting through the microphone, optionally reads a shared screen, and shows:

- a live transcript
- supplementary notes on terms and concepts that come up in the conversation
- questions worth asking right now

Everything runs locally on the Mac. No network is used at runtime.

| Stage | Implementation |
| --- | --- |
| Audio | `AVAudioEngine` mic input, 16 kHz mono, energy-based VAD chunking |
| Screen (optional) | `SCContentSharingPicker` to pick one window or display, `SCScreenshotManager` + Vision OCR each analysis tick |
| Speech-to-text | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (CoreML, default `large-v3-v20240930_626MB`) |
| Notes / questions | Apple Foundation Models (on-device), or Ollama on `127.0.0.1` |
| UI | SwiftUI window, pin button toggles always-on-top |

## Requirements

- Apple Silicon Mac, macOS 26+
- Apple Intelligence enabled (for the default LLM backend)
- Swift 6 toolchain (Command Line Tools is enough; Xcode is not required)

## Run

```sh
./scripts/build-app.sh
open build/MeetingCopilot.app
```

`swift run` also works, but the microphone permission is then granted to your terminal app.

On first launch the Whisper model (~600 MB) is downloaded to `~/Library/Application Support/MeetingCopilot/models` and compiled by CoreML, which takes a few minutes. Subsequent launches load it from disk and work offline.

## Using Ollama instead of Apple Intelligence

```sh
brew install ollama
ollama serve &
ollama pull qwen3:8b
```

Then pick "Ollama" in the LLM menu and enter the model name.

## Reading the screen

Click "画面" and pick the window or display showing the shared slides. Its text is OCR'd on-device and passed to the LLM together with the transcript; a new analysis also runs when the screen content changes. Only the picked window or display is read.

## Self-test without a microphone

```sh
say -v Kyoko -o /tmp/sample.aiff "今日は RAG の PoC について話します"
.build/debug/MeetingCopilot --selftest /tmp/sample.aiff
```

OCR on a single image:

```sh
.build/debug/MeetingCopilot --ocr /path/to/slide.png
```

## Notes

- Mic only. Remote participants in Zoom/Meet are captured only if their audio is played through speakers.
- The SwiftUI and FoundationModels macro plugins ship with Xcode only, so the code avoids `@State` and `@Generable` and builds the generation schema with `DynamicGenerationSchema`.
