# Changelog

All notable changes to SpareScreen are documented here. The project follows
semantic versioning once it reaches a stable release.

## 0.1.1 — 2026-11-11

### Changed

- Renamed the public product and repository from PhoneDisplay to SpareScreen.
- Renamed the macOS bundle to `SpareScreen.app` and the Android app label to
  SpareScreen.
- Kept internal bundle/application IDs, signing identity, and pairing storage
  unchanged so v0.1.0 release installs can update in place.
- Renamed release artifacts to `SpareScreen-<version>-*`.
- Added macOS and Android app icons and a repository logo.
- Added MIT licensing and professional repository documentation: contribution,
  security, code of conduct, issue/PR templates, CI, architecture, and
  troubleshooting.

### Fixed

- Static reconnect no longer leaves the phone on a black screen; the host
  replays the last encoded keyframe.

## 0.1.0 — 2026-11-10

### Added

- USB pairing through ADB reverse and a one-time pairing intent.
- TLS 1.2+ host identity with certificate pinning.
- Per-phone 32-byte device secrets in Android Keystore and a 0600 Mac file.
- 1920×1080@60 universal and 3120×1440@90 Galaxy S24 display profiles.
- S-Pen/cursor input, one active phone, idle teardown, and pause on Mac
  sleep/lock.
- Release-signed Android APK and ad-hoc-signed macOS DMG.
