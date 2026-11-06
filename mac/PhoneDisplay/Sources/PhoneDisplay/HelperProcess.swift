import Foundation
import PhoneDisplayCore

enum HelperError: LocalizedError {
    case missing

    var errorDescription: String? {
        "vdhelper is missing from the app bundle."
    }
}

final class HelperProcess {
    var onHeader: ((HelperHeader) -> Void)?
    var onPacket: ((HelperFrame) -> Void)?
    var onLog: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let parseQueue = DispatchQueue(label: "dev.phonedisplay.helper.stdout")
    private var parser = HelperStreamParser()
    private var stopping = false

    static func bundledURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["PHONEDISPLAY_HELPER"] {
            return URL(fileURLWithPath: override)
        }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("vdhelper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func start(
        helperURL: URL,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        synthetic: Bool
    ) throws {
        process.executableURL = helperURL
        var arguments = [
            "--stream",
            "--width", String(width),
            "--height", String(height),
            "--refresh", String(fps),
            "--fps", String(fps),
            "--bitrate", String(bitrate),
            "--name", "PhoneDisplay",
        ]
        if synthetic {
            arguments.append("--synthetic")
        }
        Diagnostics.log("helper args \(arguments.joined(separator: " "))")
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parseQueue.async {
                self?.consume(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                Diagnostics.log("helper: \(line)")
                self?.onLog?(String(line))
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self, !self.stopping else { return }
            self.onExit?(process.terminationStatus)
        }

        try process.run()
        Diagnostics.log("helper started pid=\(process.processIdentifier) synthetic=\(synthetic)")
    }

    func sendInput(kind: Int, buttons: Int, x: Int32, y: Int32) {
        write("I \(kind) \(buttons) \(x) \(y)\n")
    }

    func sendFps(_ fps: Int) {
        write("F \(fps)\n")
    }

    func requestKeyframe() {
        write("K\n")
    }

    func stop() {
        stopping = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if self.process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private func consume(_ data: Data) {
        for event in parser.append(data) {
            switch event {
            case .header(let header):
                Diagnostics.log("helper header \(header.width)x\(header.height)@\(header.fps) id=\(header.displayID ?? 0)")
                onHeader?(header)
            case .packet(let frame):
                onPacket?(frame)
            case .error(let message):
                Diagnostics.log("helper parse error: \(message)")
                onLog?(message)
            }
        }
    }

    private func write(_ string: String) {
        guard process.isRunning else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(string.utf8))
        } catch {
            onLog?("helper stdin closed: \(error.localizedDescription)")
        }
    }
}
