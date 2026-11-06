# PhoneDisplay Risk Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the four riskiest Mac assumptions before writing product code: a SwiftUI/SPM app bundle builds without Xcode, the bundled helper inherits the app’s Screen Recording and Accessibility grants, the helper produces 1080p60 frames, and a TLS listener with a pinned self-signed identity works.

**Architecture:** Throwaway SwiftUI app in a temporary directory. It spawns the existing ObjC `vdhelper` as a child, reads its stdout, and runs an `NWListener` with a self-signed TLS identity. No product code is created.

**Tech Stack:** Swift 6.4 / SwiftUI / Swift Package Manager / Network.framework / Security.framework, existing `vdhelper.m` (clang), macOS 27 SDK, Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-11-05-phonedisplay-product-design.md`

## Global Constraints

- Spike is throwaway: keep it in `/private/var/folders/m3/n6y54tvn2l93krzvvpl8jbrr0000gn/T/opencode/phonedisplay-spike`; do not add it to the product tree.
- No Apple Developer Program, notarization, or paid signing.
- Use the existing `host-macos/vdhelper.m`; do not rewrite capture/encode.
- Test display: 1920×1080, 60 fps, 10 Mbps, 8 seconds.
- TLS: self-signed P-256 or RSA identity, SHA-256 fingerprint printed by the app.
- No secrets in logs or commits.
- Manual verification only; this is a spike, not a test suite.
- Record pass/fail and exact error text; do not “fix” a failed assumption by changing the product architecture inside the spike.

## Review Focus

- Screen Recording is attributed to `PhoneDisplaySpike.app`, not to `vdhelper`; a separate helper entry means the architecture needs to change.
- Accessibility is inherited by `vdhelper`; `AXIsProcessTrusted()` inside the helper must be true after granting the app.
- A SwiftUI/SPM `.app` built with Command Line Tools launches normally and can be ad-hoc signed.
- `NWListener` TLS with a self-signed identity completes a handshake and exposes the fingerprint a phone can pin.
- The helper produces real H.264 frames at 1920×1080/60 while launched by the app, not by Terminal.

---

### Task 1: Build and launch a minimal SwiftUI/SPM app bundle

**Files:**
- Create: `$SPIKE_DIR/Package.swift`
- Create: `$SPIKE_DIR/Sources/PhoneDisplaySpike/PhoneDisplaySpikeApp.swift`
- Create: `$SPIKE_DIR/Sources/PhoneDisplaySpike/ContentView.swift`
- Create: `$SPIKE_DIR/build.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `PhoneDisplaySpike.app` with bundle id `dev.phonedisplay.spike`; `ContentView` has a status label and buttons for later tasks.

- [ ] **Step 1: Create the temporary directory and package**

```sh
SPIKE_DIR=/private/var/folders/m3/n6y54tvn2l93krzvvpl8jbrr0000gn/T/opencode/phonedisplay-spike
mkdir -p "$SPIKE_DIR/Sources/PhoneDisplaySpike"
```

`Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneDisplaySpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhoneDisplaySpike",
            path: "Sources/PhoneDisplaySpike"
        )
    ]
)
```

- [ ] **Step 2: Add the minimal app and window**

`PhoneDisplaySpikeApp.swift`:

```swift
import SwiftUI

@main
struct PhoneDisplaySpikeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

`ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @State private var status = "Not run"

    var body: some View {
        VStack(spacing: 12) {
            Text("PhoneDisplay risk spike")
                .font(.title2.bold())
            Text(status)
                .foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 220)
        .padding()
    }
}
```

- [ ] **Step 3: Add the app-bundle build script**

`build.sh` must:
- run `swift build -c release`;
- create `PhoneDisplaySpike.app/Contents/MacOS` and `Contents/Resources`;
- copy `.build/release/PhoneDisplaySpike`;
- write `Info.plist` with `CFBundleIdentifier=dev.phonedisplay.spike`, `CFBundleExecutable=PhoneDisplaySpike`, `CFBundlePackageType=APPL`, `LSMinimumSystemVersion=14.0`, `NSHighResolutionCapable=true`, `NSLocalNetworkUsageDescription=PhoneDisplay needs the local network to connect your phone.`;
- `codesign --force --deep --sign - PhoneDisplaySpike.app`.

Use `plutil -lint` on the generated `Info.plist`.

- [ ] **Step 4: Build and launch**

Run:

```sh
cd "$SPIKE_DIR"
chmod +x build.sh
./build.sh
open PhoneDisplaySpike.app
```

Expected: a window titled “PhoneDisplay risk spike” with “Not run”; `codesign -dv PhoneDisplaySpike.app` reports an ad-hoc signature; no Xcode is required.

- [ ] **Step 5: Record the result**

Append to `$SPIKE_DIR/RESULTS.md`:

```markdown
## Task 1 — SwiftUI/SPM app bundle
- Result: PASS/FAIL
- macOS:
- Swift:
- Command:
- Error (if any):
```

Do not continue if the app does not launch; the architecture changes to AppKit or an Xcode project.

---

### Task 2: Bundle the helper and verify Screen Recording / TCC inheritance

**Files:**
- Create: `$SPIKE_DIR/Sources/PhoneDisplaySpike/HelperRunner.swift`
- Modify: `$SPIKE_DIR/Sources/PhoneDisplaySpike/ContentView.swift`
- Modify: `$SPIKE_DIR/build.sh` (copy helper into `Contents/Helpers/vdhelper`)

**Interfaces:**
- Consumes: `PhoneDisplaySpike.app` from Task 1.
- Produces: `HelperRunner.run(seconds:)` starts the helper, parses stdout, and reports frame count; `onLog` receives helper stderr lines.

- [ ] **Step 1: Build and bundle the helper**

In `build.sh`, build from the existing source:

```sh
xcrun clang -fobjc-arc -fblocks -O2 -Wall \
  -isysroot "$(xcrun --show-sdk-path)" \
  -mmacosx-version-min=14.0 \
  -framework Foundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework VideoToolbox -framework ScreenCaptureKit \
  -o "$SPIKE_DIR/build/vdhelper" \
  "$HOME/phonedisplay/host-macos/vdhelper.m"
```

Copy it to `PhoneDisplaySpike.app/Contents/Helpers/vdhelper`.

- [ ] **Step 2: Add `HelperRunner`**

```swift
final class HelperRunner {
    var onFrame: ((Int) -> Void)?
    var onLog: ((String) -> Void)?
    func run(seconds: Int) throws
    func stop()
}
```

`run` launches the bundled helper with:

```text
--stream --width 1920 --height 1080 --refresh 60 --fps 60 --bitrate 10 --seconds 8
```

It reads stdout continuously, ignores the `PDH1 ...` header line, parses `u32_be length | u8 flags`, counts frames, and calls `onFrame(count)`. It reads stderr and calls `onLog` for each line. It must not block the main thread.

- [ ] **Step 3: Add the UI button and status**

In `ContentView`, add a button **Test display (8 s)**. On tap, call `HelperRunner.run(seconds: 8)` and show `frames: N`; show the last helper log line. Keep the app frontmost.

- [ ] **Step 4: Grant Screen Recording and run**

Run the app. Click **Test display**. macOS should prompt for Screen Recording for **PhoneDisplaySpike**. Grant it, quit and reopen the app if macOS requires it, then click **Test display** again.

Expected:
- A `PhoneDisplay` virtual display appears in System Settings → Displays.
- The app shows `frames: N` with `N > 0`.
- System Settings → Privacy & Security → Screen Recording lists **PhoneDisplaySpike**, not a separate `vdhelper` entry.
- The helper log contains no “screen capture permission” failure.

- [ ] **Step 5: Record the result**

Append to `RESULTS.md`:

```markdown
## Task 2 — Screen Recording / TCC
- Result: PASS/FAIL
- Frames seen:
- Screen Recording list: PhoneDisplaySpike / vdhelper / both
- Display appeared: yes/no
- Helper error (if any):
```

If `vdhelper` gets its own TCC entry, stop and record it; the product must move capture into the app or use a different helper packaging.

---

### Task 3: Verify Accessibility inheritance and input injection

**Files:**
- Create: `$SPIKE_DIR/Sources/PhoneDisplaySpike/Permissions.swift`
- Modify: `$SPIKE_DIR/Sources/PhoneDisplaySpike/HelperRunner.swift`
- Modify: `$SPIKE_DIR/Sources/PhoneDisplaySpike/ContentView.swift`

**Interfaces:**
- Consumes: `HelperRunner` from Task 2.
- Produces: `Permissions.requestAccessibility()`, `Permissions.accessibilityGranted`; `HelperRunner.sendInput(kind:buttons:x:y:)` writes one line to helper stdin.

- [ ] **Step 1: Add permission helpers**

```swift
enum Permissions {
    static func requestScreenRecording() -> Bool
    static func requestAccessibility() -> Bool
    static var accessibilityGranted: Bool { get }
}
```

Use `CGRequestScreenCaptureAccess()` for Screen Recording and
`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)` for Accessibility. Add a button **Request Accessibility**.

- [ ] **Step 2: Add input writing**

`HelperRunner.sendInput(kind:buttons:x:y:)` writes:

```text
I <kind> <buttons> <x> <y>\n
```

to the helper’s stdin. Use the existing 10-byte helper semantics: kind `0` move, `1` down, `2` up; buttons `0` left, `1` right; x/y in virtual-display pixels.

- [ ] **Step 3: Test**

1. Click **Request Accessibility**, enable **PhoneDisplaySpike** in System Settings, and relaunch the app.
2. Click **Test display** to create the virtual display.
3. Click **Test input**: send a move to `(960,540)`, then left down/up.
4. Check the helper stderr for `input injection armed` / `input: injecting events received from the phone`.

Expected: the helper reports input injection armed; the Mac pointer moves to the virtual display and the click lands. If the helper says clicks are not permitted, record that; the app grant did not reach the helper.

- [ ] **Step 4: Record the result**

Append to `RESULTS.md`:

```markdown
## Task 3 — Accessibility / input
- Result: PASS/FAIL
- Helper “input injection armed”: yes/no
- Pointer moved: yes/no
- Click landed: yes/no
- Error (if any):
```

---

### Task 4: Verify TLS listener and fingerprint pinning

**Files:**
- Create: `$SPIKE_DIR/Sources/PhoneDisplaySpike/TLSProbe.swift`
- Modify: `$SPIKE_DIR/build.sh` (generate `spike.p12` with openssl)
- Modify: `$SPIKE_DIR/Sources/PhoneDisplaySpike/ContentView.swift`

**Interfaces:**
- Consumes: app bundle from Task 1.
- Produces: `TLSProbe.start() throws -> (port: UInt16, fingerprint: String)`; listener accepts a TLS client on `127.0.0.1:9443`.

- [ ] **Step 1: Generate a throwaway identity in `build.sh`**

```sh
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$SPIKE_DIR/build/spike-key.pem" \
  -out "$SPIKE_DIR/build/spike-cert.pem" \
  -days 1 -subj "/CN=PhoneDisplaySpike"
openssl pkcs12 -export \
  -inkey "$SPIKE_DIR/build/spike-key.pem" \
  -in "$SPIKE_DIR/build/spike-cert.pem" \
  -out "$SPIKE_DIR/build/spike.p12" \
  -passout pass:spike
```

Copy `spike.p12` to `Contents/Resources/spike.p12`.

- [ ] **Step 2: Add `TLSProbe`**

Load the identity with `SecPKCS12Import` (password `spike`), get `kSecImportItemIdentity`, create a `sec_identity_t` with `sec_identity_create`, and configure:

```swift
let tls = NWProtocolTLS.Options()
sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
let listener = try NWListener(using: params, on: 9443)
```

On `newConnection`, accept and keep the connection open long enough for a handshake. Compute the SHA-256 fingerprint from the certificate data and format it as colon-separated hex.

- [ ] **Step 3: Add the UI button and run**

Add **Start TLS server**; show `port 9443` and the fingerprint. Run:

```sh
openssl s_client -connect 127.0.0.1:9443 -servername PhoneDisplaySpike </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

Expected: the command prints a SHA-256 fingerprint identical to the app’s label. No certificate verification error for the pinned test; the app’s listener accepts the connection.

- [ ] **Step 4: Record the result**

Append to `RESULTS.md`:

```markdown
## Task 4 — TLS
- Result: PASS/FAIL
- App fingerprint:
- openssl fingerprint:
- Handshake: yes/no
- Error (if any):
```

---

### Task 5: Record go/no-go and clean up

**Files:**
- Create: `docs/superpowers/specs/2026-11-06-risk-spike-results.md`
- Delete: `$SPIKE_DIR` after the results are recorded.

**Interfaces:**
- Consumes: `RESULTS.md` from Tasks 1–4.
- Produces: a one-page results document and a go/no-go decision.

- [ ] **Step 1: Write the results document**

Copy the four sections from `RESULTS.md` into
`docs/superpowers/specs/2026-11-06-risk-spike-results.md`, plus:

```markdown
## Go/no-go
- SwiftUI/SPM app bundle: go / no-go
- Screen Recording attribution: go / no-go
- Accessibility inheritance: go / no-go
- TLS pinning: go / no-go
- Architecture change needed (if any):
- Next plan:
```

- [ ] **Step 2: Verify the results document**

Run:

```sh
sed -n '1,200p' docs/superpowers/specs/2026-11-06-risk-spike-results.md
```

Expected: all four result sections present; every result is PASS or FAIL, never blank.

- [ ] **Step 3: Commit only the results**

```sh
git add docs/superpowers/specs/2026-11-06-risk-spike-results.md
git commit -m "docs: record PhoneDisplay risk spike results"
```

Do not commit `$SPIKE_DIR` or the generated identity.

- [ ] **Step 4: Clean up**

```sh
rm -rf "$SPIKE_DIR"
```

Expected: the temp directory is gone; the product tree contains only the results document.

---

## Self-Review

- Spec coverage: this plan covers the four risk assumptions in Milestone 0; it does not implement the product.
- Step scan: every step has a command or an exact interface; the manual checks are the spike’s tests.
- Type consistency: `HelperRunner`, `Permissions`, and `TLSProbe` are named once and reused.
- Review focus: each of the five risks has a task and a recorded result.
- Proportion: the plan is short because the spike is throwaway; it does not transcribe the product.
