import AppKit
import Foundation
import PhoneDisplayCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var screenRecording = false
    @Published private(set) var accessibility = false
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var clientCount = 0
    @Published private(set) var fps = 0
    @Published private(set) var frames = 0
    @Published private(set) var lastLog = ""
    @Published private(set) var pairingPayload: PairingPayload?
    @Published private(set) var pairingExpiry: Date?
    @Published private(set) var pairedDeviceName: String?
    @Published var profile: DisplayProfile {
        didSet {
            UserDefaults.standard.set(profile.rawValue, forKey: "displayProfile")
        }
    }

    private var server: HostServer?
    private var pairing: PairingService?
    private var lanHost = "127.0.0.1"
    private var port: UInt16 = 8420
    private let power = PowerAssertion()
    private var observers: [NSObjectProtocol] = []
    private var usbTimer: Timer?
    private var lastADBSerial: String?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var synthetic: Bool {
        ProcessInfo.processInfo.environment["PHONEDISPLAY_SYNTHETIC"] == "1"
            || CommandLine.arguments.contains("--synthetic")
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "displayProfile")
        profile = DisplayProfile(rawValue: saved ?? "") ?? .universal
        refreshPermissions()
        installPauseObservers()
    }

    private func installPauseObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.server?.pause(reason: "Mac is sleeping")
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.server?.resume()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.server?.pause(reason: "Mac display is asleep")
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.server?.resume()
            }
        })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.server?.pause(reason: "Mac is locked")
            }
        })
        observers.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.server?.resume()
            }
        })
    }

    func refreshPermissions() {
        screenRecording = PermissionService.screenRecording
        accessibility = PermissionService.accessibility
    }

    func requestScreenRecording() {
        PermissionService.requestScreenRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func requestAccessibility() {
        PermissionService.requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func start() {
        guard !isRunning else { return }

        if !synthetic && !screenRecording {
            status = "Grant Screen Recording, then press Start again."
            PermissionService.requestScreenRecording()
            refreshPermissions()
            return
        }

        do {
            let pairing = try PairingService()
            let server = HostServer(
                pairing: pairing,
                synthetic: synthetic,
                profile: profile
            )
            server.onState = { [weak self] state in
                DispatchQueue.main.async { self?.status = state }
            }
            server.onClientCount = { [weak self] count in
                DispatchQueue.main.async {
                    self?.clientCount = count
                    guard let self, self.isRunning else { return }
                    if count > 0 {
                        self.status = "Connected"
                    } else if self.pairedDeviceName != nil {
                        self.status = "Waiting for phone"
                    }
                }
            }
            server.onStats = { [weak self] total, currentFPS in
                DispatchQueue.main.async {
                    self?.frames = total
                    self?.fps = currentFPS
                }
            }
            server.onLog = { [weak self] line in
                let safe = self?.redact(line) ?? line
                DispatchQueue.main.async { self?.lastLog = safe }
            }
            server.onPaired = { [weak self] device in
                DispatchQueue.main.async {
                    self?.pairedDeviceName = device.name
                    self?.pairingPayload = nil
                    self?.pairingExpiry = nil
                    self?.status = "\(device.name) paired — connecting"
                    self?.clearDevPairing()
                }
            }
            server.onAuthenticated = { [weak self] device in
                DispatchQueue.main.async {
                    self?.pairedDeviceName = device.name
                }
            }

            let port = try server.start(preferredPort: 8420)
            self.server = server
            self.pairing = pairing
            self.port = port
            self.lanHost = LANAddress.primaryIPv4() ?? "127.0.0.1"
            power.start()
            isRunning = true
            Diagnostics.log("host started port=\(port)")
            beginPairing()
            startUSBTimer()
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            Diagnostics.log("host start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        usbTimer?.invalidate()
        usbTimer = nil
        server?.stop()
        server = nil
        pairing = nil
        power.stop()
        isRunning = false
        status = "Stopped"
        clientCount = 0
        fps = 0
        frames = 0
        pairingPayload = nil
        pairingExpiry = nil
        pairedDeviceName = nil
        lastADBSerial = nil
        clearDevPairing()
        Diagnostics.log("host stopped")
    }

    func beginPairing() {
        guard let pairing, isRunning else { return }
        let payload = pairing.beginPairing(host: lanHost, port: port)
        pairingPayload = payload
        pairingExpiry = pairing.pairingExpiry
        pairedDeviceName = nil
        status = "Waiting for phone — USB pairing ready"
        writeDevPairing(payload)
        Diagnostics.log("pairing window opened port=\(port)")
        lastADBSerial = nil
        maintainUSB()
    }

    private func pushPairing(_ payload: PairingPayload) {
        let port = port
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = USBLink.sendPairing(port: port, payload: payload)
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                if result.sent {
                    Diagnostics.log("USB pairing sent")
                    if self.clientCount == 0, self.pairedDeviceName == nil {
                        self.status = "Waiting for phone — USB pairing sent"
                    }
                } else {
                    Diagnostics.log("USB pairing failed: \(result.detail)")
                    if self.clientCount == 0, self.pairedDeviceName == nil {
                        self.status = "USB not ready — \(result.detail)"
                    }
                }
            }
        }
    }

    private func startUSBTimer() {
        usbTimer?.invalidate()
        usbTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maintainUSB() }
        }
    }

    private func maintainUSB() {
        guard isRunning else { return }
        let serial = USBLink.connectedSerial()
        if let serial {
            if serial != lastADBSerial {
                lastADBSerial = serial
                if clientCount == 0, pairedDeviceName == nil, let payload = pairingPayload {
                    // The phone may have been plugged in after Start.
                    pushPairing(payload)
                    return
                }
            }
        } else {
            lastADBSerial = nil
            if clientCount == 0, pairedDeviceName == nil, pairingPayload != nil {
                status = "USB not ready — no authorized Android device"
            }
        }
        let port = port
        // USB unplug/replug drops `adb reverse`; restore it so a saved phone
        // can reconnect without pressing anything on the Mac.
        DispatchQueue.global(qos: .utility).async {
            _ = USBLink.ensureReverse(port: port)
        }
    }

    func refreshPairing() {
        guard isRunning, let pairing else { return }
        if pairing.pairingIsOpen {
            pairingExpiry = pairing.pairingExpiry
            if pairingPayload == nil, pairedDeviceName == nil {
                beginPairing()
            }
        } else if pairingPayload != nil {
            pairingPayload = nil
            pairingExpiry = nil
            if pairedDeviceName == nil {
                status = "Pairing expired — press Send pairing again"
            }
        }
    }

    func openScreenRecordingSettings() {
        PermissionService.openScreenRecordingSettings()
    }

    func openAccessibilitySettings() {
        PermissionService.openAccessibilitySettings()
    }

    func openLocalNetworkSettings() {
        PermissionService.openLocalNetworkSettings()
    }

    func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func redact(_ line: String) -> String {
        var safe = line
        if let token = pairingPayload?.token {
            safe = safe.replacingOccurrences(of: token, with: "<redacted>")
        }
        return safe
    }

    private func writeDevPairing(_ payload: PairingPayload) {
        guard ProcessInfo.processInfo.environment["PHONEDISPLAY_DEV"] == "1" else {
            return
        }
        let url = PairingService.defaultDirectory()
            .appendingPathComponent("dev-pairing.json")
        let object: [String: Any] = [
            "url": payload.url,
            "fingerprint": payload.fingerprint,
            "port": Int(payload.port),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func clearDevPairing() {
        let url = PairingService.defaultDirectory()
            .appendingPathComponent("dev-pairing.json")
        try? FileManager.default.removeItem(at: url)
    }
}
