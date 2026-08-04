# Contributing

Thanks for helping improve WhisprGo.

## Development

WhisprGo requires macOS 14 or newer, Apple silicon for practical local-model work, and Xcode 26 / Swift 6.2 or newer.

```sh
swift test
zsh Scripts/build-app.sh
```

Keep work on the audio callback allocation-free and non-blocking. UI changes must not publish audio levels through SwiftUI or queue one task per audio packet. See [Architecture](docs/ARCHITECTURE.md) before changing capture, model lifetime, or the recording overlay.

## Pull requests

- Keep each pull request focused.
- Include tests for behavior changes where practical.
- Describe performance or privacy tradeoffs explicitly.
- Never commit model downloads, recordings, transcripts, credentials, or signing material.
