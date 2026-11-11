# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | Yes |
| Older | No |

## Reporting a vulnerability

Please report security issues privately through GitHub Security Advisories:

**https://github.com/pratham-rog/sparescreen/security/advisories/new**

Do not open a public issue for a vulnerability. Include:

- affected version and platform;
- a clear description of the issue and impact;
- reproduction steps or a minimal proof of concept;
- whether a physical phone or USB access is required;
- any suggested fix.

You should receive an acknowledgement within a few days. Please give the
maintainer reasonable time to investigate and ship a fix before public
disclosure.

## Scope

Security-sensitive areas include:

- TLS certificate pinning and the pairing handshake;
- one-time pairing token generation, expiry, and one-use enforcement;
- per-device secret storage (Android Keystore and the 0600 Mac file);
- the local TLS listener and USB/ADB reverse mapping;
- input injection, cursor/pen handling, and display lifecycle;
- release signing and update continuity.

## Secrets and logs

Never share:

- pairing payloads or pairing tokens;
- device secrets or `devices.json`;
- `android/keystore.properties` or release keystores;
- `host-macos/stream.log`, which may contain a legacy token.

The secure app does not print pairing tokens or device secrets. Redact host IDs,
ports, and phone names before posting diagnostics.

## Safe harbor

Good-faith research that follows this policy, avoids privacy violations and
service disruption, and gives the maintainer time to respond will not be
pursued by the project.
