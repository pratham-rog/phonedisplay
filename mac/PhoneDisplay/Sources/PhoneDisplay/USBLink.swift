import Foundation
import PhoneDisplayCore

/// Delivers the one-time pairing payload to the Android app over the
/// authorized ADB/USB link. The payload is base64-encoded so no shell
/// metacharacters reach `adb shell`.
enum USBLink {
    struct Result {
        let sent: Bool
        let detail: String
    }

    private static let androidPackage = "dev.phonedisplay.app"

    static func connectedSerial() -> String? {
        guard let adb = adbPath() else { return nil }
        return deviceSerial(adb: adb)
    }

    static func ensureReverse(port: UInt16) -> Bool {
        guard let adb = adbPath(), let serial = deviceSerial(adb: adb) else {
            return false
        }
        return run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]).status == 0
    }

    static func sendPairing(port: UInt16, payload: PairingPayload) -> Result {
        guard let adb = adbPath() else {
            return Result(sent: false, detail: "adb not found")
        }
        guard let serial = deviceSerial(adb: adb) else {
            return Result(sent: false, detail: "no authorized Android device")
        }

        _ = run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])

        let usbPayload = PairingPayload(
            host: "127.0.0.1",
            port: port,
            fingerprint: payload.fingerprint,
            token: payload.token,
            hostID: payload.hostID,
            name: payload.name
        )
        let encoded = Data(usbPayload.url.utf8).base64EncodedString()
        let start = run(adb, [
            "-s", serial, "shell", "am", "start", "-n",
            "\(androidPackage)/.MainActivity",
            "--es", "pd_pairing_b64", encoded,
        ])
        guard start.status == 0 else {
            return Result(sent: false, detail: "could not start the Android app")
        }
        return Result(sent: true, detail: serial)
    }

    private static func adbPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PHONEDISPLAY_ADB"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/Applications/Android Studio.app/Contents/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func deviceSerial(adb: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let serial = environment["PHONEDISPLAY_ADB_SERIAL"], !serial.isEmpty {
            return serial
        }
        let result = run(adb, ["devices"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if fields.count >= 2, fields[1] == "device" {
                return String(fields[0])
            }
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
