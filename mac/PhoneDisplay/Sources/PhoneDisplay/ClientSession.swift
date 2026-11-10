import Foundation
import Network
import PhoneDisplayCore

protocol ClientSessionDelegate: AnyObject {
    func sessionDidPair(_ session: ClientSession, device: KnownDevice)
    func session(_ session: ClientSession, didHello device: KnownDevice)
    func session(_ session: ClientSession, didReceiveInput payload: Data)
    func session(_ session: ClientSession, didReceiveControl payload: Data)
    func sessionDidClose(_ session: ClientSession)
    func session(_ session: ClientSession, log: String)
}

final class ClientSession {
    let connection: NWConnection
    var deviceID: String?
    var deviceName: String?
    var heldButton = -1
    var lastX: Int32 = 0
    var lastY: Int32 = 0
    var isReady = false

    weak var delegate: ClientSessionDelegate?
    private let pairing: PairingService
    private let queue = DispatchQueue(label: "dev.phonedisplay.session")
    private var buffer = Data()
    private var lastReceive = Date()
    private var heartbeat: DispatchSourceTimer?
    private let lock = NSLock()
    private var closed = false

    init(connection: NWConnection, pairing: PairingService) {
        self.connection = connection
        self.pairing = pairing
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readLine()
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func sendError(_ code: String, _ message: String, closeAfterSend: Bool = true) {
        sendJSON(
            ["type": "error", "code": code, "message": message],
            completion: closeAfterSend ? { [weak self] in self?.close() } : nil
        )
    }

    func sendStream(width: Int, height: Int, fps: Int, bitrate: Int, codec: String, fallback: Bool) {
        sendJSON([
            "type": "stream",
            "v": 1,
            "width": width,
            "height": height,
            "fps": fps,
            "bitrate": bitrate,
            "codec": codec,
            "fallback": fallback,
        ])
    }

    func sendFrame(flags: UInt8, payload: Data) {
        var data = Data([
            UInt8((payload.count >> 24) & 0xFF),
            UInt8((payload.count >> 16) & 0xFF),
            UInt8((payload.count >> 8) & 0xFF),
            UInt8(payload.count & 0xFF),
            flags,
        ])
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
        })
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
        delegate?.sessionDidClose(self)
    }

    private func readLine() {
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            handleLine(line)
            return
        }
        guard buffer.count <= 64 << 10 else {
            close()
            return
        }
        receiveMore { [weak self] data in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                self.readLine()
            } else {
                self.close()
            }
        }
    }

    private func handleLine(_ data: Data) {
        lastReceive = Date()
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let type = message["type"] as? String
        else {
            sendError("version", "Malformed handshake. Update PhoneDisplay.", closeAfterSend: true)
            return
        }

        switch type {
        case "pair":
            handlePair(message)
        case "hello":
            handleHello(message)
        default:
            sendError("version", "Unknown handshake. Update PhoneDisplay.", closeAfterSend: true)
        }
    }

    private func handlePair(_ message: [String: Any]) {
        guard let token = message["token"] as? String,
              pairing.validatePairingToken(token)
        else {
            sendError("pairing", "Pairing expired — press Send pairing again on the Mac.")
            return
        }
        let deviceInfo = message["device"] as? [String: Any]
        let name = deviceInfo?["name"] as? String ?? "Android phone"
        let device = pairing.createDevice(name: name)
        sendJSON([
            "type": "paired",
            "v": 1,
            "deviceId": device.id,
            "secret": device.secret,
        ])
        delegate?.sessionDidPair(self, device: device)
        readLine()
    }

    private func handleHello(_ message: [String: Any]) {
        guard let deviceID = message["deviceId"] as? String,
              let auth = message["auth"] as? String,
              let device = pairing.authenticate(deviceID: deviceID, secret: auth)
        else {
            sendError("revoked", "Pair this phone again.")
            return
        }
        self.deviceID = device.id
        self.deviceName = device.name
        lastReceive = Date()
        delegate?.session(self, didHello: device)
        startHeartbeat()
        readBinary()
    }

    private func readBinary() {
        readExactly(5) { [weak self] header in
            guard let self, let header else {
                self?.close()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            let flags = header[4]
            guard length > 0, length <= 8 << 20 else {
                self.close()
                return
            }
            self.readExactly(Int(length)) { [weak self] payload in
                guard let self, let payload else {
                    self?.close()
                    return
                }
                self.lastReceive = Date()
                if flags == 0x04 {
                    if payload.first == 0x7B {
                        self.delegate?.session(self, didReceiveControl: payload)
                    } else if payload.count == 10 {
                        self.delegate?.session(self, didReceiveInput: payload)
                    } else {
                        self.close()
                        return
                    }
                }
                self.readBinary()
            }
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceive) > 15 {
                self.close()
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func sendJSON(_ object: [String: Any], completion: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            completion?()
            return
        }
        var line = data
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            } else {
                completion?()
            }
        })
    }

    private func readExactly(_ count: Int, completion: @escaping (Data?) -> Void) {
        if buffer.count >= count {
            let data = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            completion(data)
            return
        }
        receiveMore { [weak self] data in
            guard let self else {
                completion(nil)
                return
            }
            if let data {
                self.buffer.append(data)
                self.readExactly(count, completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    private func receiveMore(_ completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
            data, _, isComplete, error in
            if error != nil {
                completion(nil)
                return
            }
            if let data, !data.isEmpty {
                completion(data)
                return
            }
            if isComplete {
                completion(nil)
            } else {
                completion(nil)
            }
        }
    }
}
