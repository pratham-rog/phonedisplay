import Foundation

public struct HelperHeader: Equatable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let codec: String
    public let displayID: UInt32?

    public init(width: Int, height: Int, fps: Int, codec: String, displayID: UInt32?) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.displayID = displayID
    }
}

public struct HelperFrame: Equatable {
    public let flags: UInt8
    public let payload: Data

    public init(flags: UInt8, payload: Data) {
        self.flags = flags
        self.payload = payload
    }
}

public enum HelperStreamEvent: Equatable {
    case header(HelperHeader)
    case packet(HelperFrame)
    case error(String)
}

/// Parses vdhelper stdout: one `PDH1 ...` line, then `u32be length | u8 flags | payload`.
public struct HelperStreamParser {
    private enum State {
        case header
        case frames
        case failed
    }

    private var state: State = .header
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) -> [HelperStreamEvent] {
        buffer.append(contentsOf: data)
        var events: [HelperStreamEvent] = []

        while true {
            switch state {
            case .header:
                guard let newline = buffer.firstIndex(of: 0x0A) else {
                    return events
                }
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeFirst(newline + 1)
                let parts = line.split(separator: " ")
                guard parts.count >= 5,
                      parts[0] == "PDH1",
                      let width = Int(parts[1]),
                      let height = Int(parts[2]),
                      let fps = Int(parts[3])
                else {
                    state = .failed
                    events.append(.error("Unexpected helper header: \(line)"))
                    return events
                }
                let displayID = parts.count > 5 ? UInt32(parts[5]) : nil
                events.append(.header(HelperHeader(
                    width: width,
                    height: height,
                    fps: fps,
                    codec: String(parts[4]),
                    displayID: displayID
                )))
                state = .frames

            case .frames:
                guard buffer.count >= 5 else {
                    return events
                }
                let length = (UInt32(buffer[0]) << 24)
                    | (UInt32(buffer[1]) << 16)
                    | (UInt32(buffer[2]) << 8)
                    | UInt32(buffer[3])
                let flags = buffer[4]
                guard length > 0, length <= 32 << 20 else {
                    state = .failed
                    events.append(.error("Invalid helper frame length: \(length)"))
                    return events
                }
                let total = 5 + Int(length)
                guard buffer.count >= total else {
                    return events
                }
                let payload = Data(buffer[5..<total])
                buffer.removeFirst(total)
                events.append(.packet(HelperFrame(flags: flags, payload: payload)))

            case .failed:
                buffer.removeAll()
                return events
            }
        }
    }
}
