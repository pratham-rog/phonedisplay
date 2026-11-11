# Contributing to SpareScreen

Thanks for helping make SpareScreen better. This project is a native macOS host
and Android client that turn a phone into a USB second display. Small, focused
changes with tests and honest hardware notes are more useful than large
unverified rewrites.

## Before you start

- Read [README.md](README.md) and [docs/architecture.md](docs/architecture.md).
- Check existing issues and pull requests.
- For security problems, follow [SECURITY.md](SECURITY.md), not a public issue.
- By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Development setup

### macOS

Requirements: macOS 14+, Command Line Tools, and a Swift toolchain.

```sh
cd mac/PhoneDisplay
./build.sh
open SpareScreen.app
```

The app uses a stable local signing identity when available. If it falls back
to ad-hoc signing, macOS may ask for Screen Recording and Accessibility again
after a rebuild.

### Android

Requirements: JDK 17 and Android SDK platform 34.

```sh
cd android
./gradlew test
./gradlew :app:assembleDebug
```

Release builds use `android/keystore.properties` and a local release keystore.
That file and the keystore are git-ignored and must never be committed.

## Tests

Run the checks that match your change:

```sh
cd mac/PhoneDisplay
swift run -c release PhoneDisplayCoreChecks

cd android
./gradlew test
```

Changes to pairing, TLS, framing, input, or display geometry need a test or a
clear hardware verification note. Do not claim a physical S-Pen, sleep/lock, or
macOS-version check that you did not actually run.

## Code style

- Keep the existing structure: native SwiftUI/Kotlin, no unnecessary
  dependencies.
- Prefer small, readable changes over new abstractions.
- Keep public behavior and error messages clear.
- Do not rename internal bundle/application IDs, keychain aliases, or pairing
  storage without a migration plan; they are part of the upgrade contract.
- Comments should explain why, not repeat the code.

## Security rules

- Never commit pairing tokens, device secrets, TLS private keys, keystores,
  `android/keystore.properties`, or `host-macos/stream.log`.
- Redact host IDs and tokens from logs in issues and pull requests.
- Do not weaken certificate pinning, token expiry, one-phone enforcement, or
  secret storage to make a test pass.
- Keep the TLS listener bound to the USB reverse path unless a design change is
  reviewed first.

## Pull requests

1. Keep the change focused.
2. Include tests or a hardware verification note.
3. Update README/docs when behavior, setup, or limits change.
4. Run the relevant test commands.
5. Fill in the pull-request template, including security and hardware notes.

Maintainers may ask for a smaller diff or a manual hardware check before merge.

## Release notes

Release builds are produced with `tools/package_release.sh` and signed with the
local release key. Only maintainers with the release key should publish
artifacts. Back up the keystore and `android/keystore.properties`; losing them
breaks update continuity for existing installs.
