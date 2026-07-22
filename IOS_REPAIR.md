# iOS repair notes

This source tree is based on the current public Monochrome repository and replaces the supplied legacy IPA project.

## What changed

- The Shaka player no longer waits for every page image before initializing. Lazy-loaded search artwork could otherwise leave playback waiting forever on iPhone.
- The obsolete `streaming.jumpLargeGaps` setting was removed for Shaka 5.
- The official `https://monochrome.tf` origin remains in the native configuration because its account, Cloudflare, and stream services reject a local Capacitor origin.
- `NativeBridgeViewController` applies the playback startup workaround at document start, before the remote application executes.
- The iPhone layout uses safe-area-aware spacing, a sticky header, two-column cards, and a compact 68-point mini-player.
- The native app configures an iOS playback audio session and retains the `audio` background mode.

## Build and sign on macOS

1. Install Xcode and its command-line tools.
2. In the repository root, run `npm install`.
3. Run `npm run build`.
4. Run `npx cap sync ios`.
5. Open `ios/App/App.xcodeproj` in Xcode.
6. Select your Apple developer team and a unique bundle identifier if required.
7. Build to an iPhone 12 or archive and export an IPA.

An IPA cannot be compiled or signed on Windows. Sideloading tools may re-sign an exported IPA, but they cannot turn the supplied compiled binary into this updated native target.

## Audio scope

Monochrome currently resolves some streams and decrypts some providers in its web client, including blob-backed streams that a standalone `AVPlayer` cannot open. This repair fixes the iPhone playback deadlock and preserves iOS background audio, but it does not pretend that all provider playback has been migrated to `AVPlayer`. A complete native player would require a documented server endpoint that returns an AVFoundation-compatible authenticated URL.
