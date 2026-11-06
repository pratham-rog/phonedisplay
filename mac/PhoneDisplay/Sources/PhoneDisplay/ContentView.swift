import Combine
import PhoneDisplayCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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

                if model.isRunning {
                    connection
                }

                if !model.lastLog.isEmpty {
                    Text(model.lastLog)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Text("Development build: plain TCP. TLS pairing is the next slice.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
        .frame(width: 620, height: 780)
        .onAppear { model.refreshPermissions() }
        .onReceive(timer) { _ in model.refreshPermissions() }
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

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Connect your phone")
                .font(.headline)

            HStack(alignment: .top, spacing: 18) {
                if let qr = model.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let info = model.connectionInfo {
                        Text("Mac address")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(info.host):\(info.port)")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)

                        Text("Connection string for the current Android app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(info.connectionString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)

                        Button("Copy connection string") {
                            model.copyConnectionString()
                        }
                        .controlSize(.small)
                    }

                    HStack(spacing: 14) {
                        Label("\(model.clientCount) connected", systemImage: "iphone")
                        Label("\(model.fps) fps", systemImage: "speedometer")
                        Label("\(model.frames) frames", systemImage: "film")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("The QR is for the new Android app. For now, paste the connection string into the current app's address field.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
