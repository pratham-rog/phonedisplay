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
    @Published private(set) var connectionInfo: ConnectionInfo?
    @Published private(set) var qrImage: NSImage?

    private var hub: StreamHub?
    private var token = ""
    private let power = PowerAssertion()

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var synthetic: Bool {
        ProcessInfo.processInfo.environment["PHONEDISPLAY_SYNTHETIC"] == "1"
            || CommandLine.arguments.contains("--synthetic")
    }

    init() {
        refreshPermissions()
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
            token = try TokenStore.loadOrCreate(at: TokenStore.defaultURL)
            let host = LANAddress.primaryIPv4() ?? "127.0.0.1"
            let hub = StreamHub(token: token, synthetic: synthetic)
            hub.onState = { [weak self] state in
                DispatchQueue.main.async { self?.status = state }
            }
            hub.onClientCount = { [weak self] count in
                DispatchQueue.main.async { self?.clientCount = count }
            }
            hub.onStats = { [weak self] total, currentFPS in
                DispatchQueue.main.async {
                    self?.frames = total
                    self?.fps = currentFPS
                }
            }
            hub.onLog = { [weak self] line in
                let safe = self?.redact(line) ?? line
                DispatchQueue.main.async { self?.lastLog = safe }
            }

            let port = try hub.start(preferredPort: 8420)
            self.hub = hub
            power.start()
            isRunning = true
            status = "Waiting for phone"

            let info = ConnectionInfo(host: host, port: port, token: token)
            connectionInfo = info
            qrImage = QRCode.image(for: info.qrPayload)
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        hub?.stop()
        hub = nil
        power.stop()
        isRunning = false
        status = "Stopped"
        clientCount = 0
        fps = 0
        frames = 0
        connectionInfo = nil
        qrImage = nil
    }

    func copyConnectionString() {
        guard let value = connectionInfo?.connectionString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
        guard !token.isEmpty else { return line }
        return line.replacingOccurrences(of: token, with: "<redacted>")
    }
}
