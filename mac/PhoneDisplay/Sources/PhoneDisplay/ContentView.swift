import Combine
import PhoneDisplayCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                permissions
                Divider()

                HStack(spacing: 12) {
                    Button(model.isRunning ? "Stop" : "Start PhoneDisplay") {
                        model.isRunning ? model.stop() : model.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text(model.status)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text("Display profile")
                            .font(.headline)
                        Picker("Display profile", selection: $model.profile) {
                            ForEach(DisplayProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 330)
                        .disabled(model.isRunning)
                    }
                    Text(model.profile.detail + (model.isRunning ? " Applies when you restart." : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.isRunning {
                    pairing
                }

                if !model.lastLog.isEmpty {
                    Text(model.lastLog)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Text("Secure TLS pairing. The QR expires after two minutes and pairs one phone.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
        .frame(width: 620, height: 780)
        .onAppear {
            model.refreshPermissions()
            model.refreshPairing()
        }
        .onReceive(timer) { _ in
            model.refreshPermissions()
            model.refreshPairing()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("PhoneDisplay")
                    .font(.largeTitle.bold())
                Text("Use your Android phone as a second Mac display.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(model.version)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Permissions")
                    .font(.headline)
                Spacer()
                Button("Restart app") { model.restart() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }

            PermissionRow(
                title: "Screen Recording",
                detail: "Required to capture the virtual display.",
                granted: model.screenRecording,
                action: model.requestScreenRecording,
                openSettings: model.openScreenRecordingSettings
            )
            PermissionRow(
                title: "Accessibility",
                detail: "Required for clicks and S-Pen input. Pointer movement works without it.",
                granted: model.accessibility,
                action: model.requestAccessibility,
                openSettings: model.openAccessibilitySettings
            )

            HStack {
                Text("Local Network is only needed if macOS asks while starting.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Open") { model.openLocalNetworkSettings() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            if let device = model.pairedDeviceName {
                HStack(spacing: 8) {
                    Image(systemName: model.clientCount > 0 ? "checkmark.circle.fill" : "iphone")
                        .foregroundStyle(model.clientCount > 0 ? .green : .secondary)
                    Text(device)
                        .font(.headline)
                    Spacer()
                    Text(model.clientCount > 0 ? "Connected" : "Waiting for phone")
                        .foregroundStyle(.secondary)
                }
                if model.clientCount == 0 {
                    Button("Show a new pairing QR") { model.beginPairing() }
                        .controlSize(.small)
                }
            } else if let qr = model.qrImage, let payload = model.pairingPayload {
                Text("Pair your phone")
                    .font(.headline)
                HStack(alignment: .top, spacing: 18) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 190, height: 190)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Open PhoneDisplay on Android and scan this code.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Mac: \(payload.host):\(payload.port)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        if let expiry = model.pairingExpiry {
                            Text("Expires \(expiry, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("This QR carries a one-time bootstrap secret; the long-lived device secret is issued after pairing.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                Button("Show a new QR") { model.beginPairing() }
                    .controlSize(.small)
            } else {
                Text("Pairing expired")
                    .font(.headline)
                Text("Show a new QR on the Mac to pair this phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show a new QR") { model.beginPairing() }
                    .controlSize(.small)
            }

            stats
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            Label("\(model.clientCount) connected", systemImage: "iphone")
            Label("\(model.fps) fps", systemImage: "speedometer")
            Label("\(model.frames) frames", systemImage: "film")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.body.weight(.medium))
                    Text(granted ? "Granted" : "Needs permission")
                        .font(.caption)
                        .foregroundStyle(granted ? .green : .orange)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant") { action() }
                    .controlSize(.small)
                Button("Settings") { openSettings() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
