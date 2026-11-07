import Foundation
import Network
import PhoneDisplayCore
import Security

enum HostServerError: LocalizedError {
    case noPort
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .noPort:
            return "No free local port was found."
        case .listener(let message):
            return "Could not start the secure listener: \(message)"
        }
    }
}

final class HostServer: ClientSessionDelegate {
    var onState: ((String) -> Void)?
    var onClientCount: ((Int) -> Void)?
    var onStats: ((Int, Int) -> Void)?
    var onLog: ((String) -> Void)?
    var onPaired: ((KnownDevice) -> Void)?

    private let pairing: PairingService
    private let synthetic: Bool
    private let profile: DisplayProfile
    private let queue = DispatchQueue(label: "dev.phonedisplay.host")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ClientSession] = [:]
    private var ready: Set<ObjectIdentifier> = []
    private var activeSession: ClientSession?
    private var helper: HelperProcess?
    private var headerLine: String?
    private var streamHeader: HelperHeader?
    private var cache: [CachedFrame] = []
    private var cacheBytes = 0
    private var lastCursor: CachedFrame?
    private var idleWork: DispatchWorkItem?
    private var headerTimeoutWork: DispatchWorkItem?
    private var totalFrames = 0
    private var fpsFrames = 0
    private var fpsStart = Date()
    private var stopped = false

    private struct CachedFrame {
        let flags: UInt8
        let payload: Data
    }

    init(pairing: PairingService, synthetic: Bool, profile: DisplayProfile) {
        self.pairing = pairing
        self.synthetic = synthetic
        self.profile = profile
    }

    func start(preferredPort: UInt16) throws -> UInt16 {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(pairing.identity.identity) else {
            throw HostServerError.listener("The TLS identity could not be converted.")
        }
        sec_protocol_options_set_local_identity(
            tls.securityProtocolOptions,
            secIdentity
        )
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        var lastError: Error?

        for candidate in preferredPort..<(preferredPort + 20) {
            guard let endpoint = NWEndpoint.Port(rawValue: candidate) else {
                continue
            }
            do {
                let listener = try NWListener(using: parameters, on: endpoint)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                let ready = DispatchSemaphore(value: 0)
                var startError: Error?
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        ready.signal()
                    case .failed(let error):
                        startError = error
                        ready.signal()
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                guard ready.wait(timeout: .now() + 2) == .success,
                      startError == nil
                else {
                    lastError = startError
                    listener.cancel()
                    continue
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        Diagnostics.log("TLS listener failed: \(error)")
                        self?.onState?("Secure listener failed: \(error.localizedDescription)")
                    }
                }
                self.listener = listener
                Diagnostics.log("TLS listener ready on port \(candidate)")
                onState?("Waiting for phone")
                return candidate
            } catch {
                lastError = error
            }
        }
        throw HostServerError.listener(
            lastError?.localizedDescription ?? "No secure port was available."
        )
    }

    func stop() {
        stopped = true
        idleWork?.cancel()
        idleWork = nil
        listener?.cancel()
        listener = nil
        closeAllSessions()
        stopHelper()
    }

    /// Sleep/lock must release the virtual display and the phone connection.
    /// The listener stays up so the phone can reconnect after wake/unlock.
    func pause(reason: String) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.idleWork?.cancel()
            self.idleWork = nil
            self.closeAllSessions()
            self.stopHelper()
            self.onState?(reason)
            Diagnostics.log("host paused: \(reason)")
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onState?("Waiting for phone")
            Diagnostics.log("host resumed")
        }
    }

    func sessionDidPair(_ session: ClientSession, device: KnownDevice) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            Diagnostics.log("paired device name=\(device.name) id=\(device.id)")
            self.onPaired?(device)
            self.onState?("Phone paired — waiting for hello")
        }
    }

    func session(_ session: ClientSession, didHello device: KnownDevice) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if let active = self.activeSession, active !== session {
                if active.deviceID != device.id {
                    session.sendError("busy", "This Mac is already in use.")
                    return
                }
                active.close()
            }
            self.activeSession = session
            self.idleWork?.cancel()
            self.idleWork = nil
            self.onClientCount?(1)
            self.onState?("\(device.name) connected")
            Diagnostics.log("authenticated device id=\(device.id)")
            if self.helper != nil {
                _ = self.sendStreamAndCache(to: session)
            } else {
                self.startHelper()
            }
        }
    }

    func session(_ session: ClientSession, didReceiveInput payload: Data) {
        queue.async { [weak self] in
            guard let self, !self.stopped, session === self.activeSession,
                  payload.count == 10
            else {
                return
            }
            let kind = Int(payload[0])
            let buttons = Int(payload[1] & 1)
            let x = self.int32BE(payload, 2)
            let y = self.int32BE(payload, 6)
            session.lastX = x
            session.lastY = y
            if kind == 1 {
                session.heldButton = buttons
            } else if kind == 2 {
                session.heldButton = -1
            }
            self.helper?.sendInput(kind: kind, buttons: buttons, x: x, y: y)
        }
    }

    func session(_ session: ClientSession, didReceiveControl payload: Data) {
        queue.async { [weak self] in
            guard let self, !self.stopped, session === self.activeSession,
                  let object = try? JSONSerialization.jsonObject(with: payload),
                  let message = object as? [String: Any],
                  let type = message["type"] as? String
            else {
                return
            }
            switch type {
            case "fps":
                if let value = message["value"] as? Int {
                    self.helper?.sendFps(value)
                }
            case "keyframe":
                self.helper?.requestKeyframe()
            case "heartbeat", "stats":
                break
            default:
                break
            }
        }
    }

    func sessionDidClose(_ session: ClientSession) {
        queue.async { [weak self] in
            guard let self else { return }
            let id = ObjectIdentifier(session)
            self.sessions.removeValue(forKey: id)
            self.ready.remove(id)
            if session.heldButton >= 0 {
                self.helper?.sendInput(
                    kind: 2,
                    buttons: session.heldButton,
                    x: session.lastX,
                    y: session.lastY
                )
                session.heldButton = -1
            }
            guard session === self.activeSession else { return }
            self.activeSession = nil
            self.onClientCount?(0)
            self.onState?("Waiting for phone")
            self.scheduleIdleStop()
        }
    }

    func session(_ session: ClientSession, log: String) {
        onLog?(log)
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                connection.cancel()
                return
            }
            let session = ClientSession(connection: connection, pairing: self.pairing)
            session.delegate = self
            self.sessions[ObjectIdentifier(session)] = session
            session.start()
        }
    }

    private func startHelper() {
        guard helper == nil, !stopped else { return }
        let process = HelperProcess()
        process.onHeader = { [weak self] header in
            self?.queue.async { self?.didReceiveHeader(header) }
        }
        process.onPacket = { [weak self] frame in
            self?.queue.async { self?.didReceiveFrame(frame) }
        }
        process.onLog = { [weak self] line in
            self?.queue.async { self?.onLog?(line) }
        }
        process.onExit = { [weak self] status in
            self?.queue.async { self?.helperExited(status) }
        }

        do {
            guard let url = HelperProcess.bundledURL() else {
                throw HelperError.missing
            }
            try process.start(
                helperURL: url,
                width: profile.width,
                height: profile.height,
                fps: profile.fps,
                bitrate: profile.bitrate,
                synthetic: synthetic
            )
            helper = process
            totalFrames = 0
            fpsFrames = 0
            fpsStart = Date()
            onStats?(0, 0)
            onState?("Starting virtual display")
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.headerLine == nil, self.helper != nil else { return }
                Diagnostics.log("helper header timeout")
                self.onState?("Virtual display did not start")
                self.stopHelper()
                self.closeAllSessions()
            }
            headerTimeoutWork = timeout
            queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        } catch {
            onState?("Could not start virtual display: \(error.localizedDescription)")
            closeAllSessions()
        }
    }

    private func didReceiveHeader(_ header: HelperHeader) {
        guard !stopped else { return }
        headerTimeoutWork?.cancel()
        headerTimeoutWork = nil
        streamHeader = header
        headerLine = "PDH1 \(header.width) \(header.height) \(header.fps) \(header.codec)\n"
        Diagnostics.log("secure hub header \(header.width)x\(header.height)@\(header.fps)")
        onState?("Streaming \(header.width)x\(header.height) @ \(header.fps) fps")
        for session in sessions.values where session === activeSession {
            _ = sendStreamAndCache(to: session)
        }
    }

    private func didReceiveFrame(_ frame: HelperFrame) {
        guard !stopped else { return }
        if frame.flags & 0x02 != 0 {
            let cursor = CachedFrame(flags: frame.flags, payload: frame.payload)
            lastCursor = cursor
            broadcast(cursor)
            return
        }
        let cached = CachedFrame(flags: frame.flags, payload: frame.payload)
        if frame.flags & 0x01 != 0 {
            cache = [cached]
            cacheBytes = frame.payload.count
        } else if !cache.isEmpty {
            cache.append(cached)
            cacheBytes += frame.payload.count
            if cache.count > 500 || cacheBytes > (16 << 20) {
                cache = []
                cacheBytes = 0
            }
        }
        broadcast(cached)

        totalFrames += 1
        fpsFrames += 1
        if Date().timeIntervalSince(fpsStart) >= 1 {
            onStats?(totalFrames, fpsFrames)
            fpsFrames = 0
            fpsStart = Date()
        }
    }

    private func helperExited(_ status: Int32) {
        guard !stopped else { return }
        helper = nil
        headerLine = nil
        streamHeader = nil
        cache = []
        cacheBytes = 0
        lastCursor = nil
        onState?("Virtual display stopped (helper exit \(status))")
        closeAllSessions()
    }

    private func sendStreamAndCache(to session: ClientSession) -> Bool {
        guard let header = streamHeader else { return false }
        let id = ObjectIdentifier(session)
        guard !ready.contains(id) else { return true }
        session.sendStream(
            width: header.width,
            height: header.height,
            fps: header.fps,
            bitrate: profile.bitrate,
            codec: header.codec,
            fallback: false
        )
        for frame in cache {
            session.sendFrame(flags: frame.flags, payload: frame.payload)
        }
        if let lastCursor {
            session.sendFrame(flags: lastCursor.flags, payload: lastCursor.payload)
        }
        ready.insert(id)
        session.isReady = true
        Diagnostics.log("sent stream header + \(cache.count) cached frames")
        return true
    }

    private func broadcast(_ frame: CachedFrame) {
        for (id, session) in sessions where ready.contains(id) {
            session.sendFrame(flags: frame.flags, payload: frame.payload)
        }
    }

    private func scheduleIdleStop() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.activeSession == nil else { return }
            self.stopHelper()
            self.onState?("Waiting for phone")
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func stopHelper() {
        headerTimeoutWork?.cancel()
        headerTimeoutWork = nil
        helper?.onExit = nil
        helper?.stop()
        helper = nil
        headerLine = nil
        streamHeader = nil
        cache = []
        cacheBytes = 0
        lastCursor = nil
        ready.removeAll()
        totalFrames = 0
        fpsFrames = 0
        onStats?(0, 0)
    }

    private func closeAllSessions() {
        let all = sessions.values
        sessions.removeAll()
        ready.removeAll()
        activeSession = nil
        for session in all {
            session.close()
        }
        onClientCount?(0)
    }

    private func int32BE(_ data: Data, _ offset: Int) -> Int32 {
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        return Int32(bitPattern: value)
    }
}
