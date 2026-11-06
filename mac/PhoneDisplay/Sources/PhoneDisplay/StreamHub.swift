import Foundation
import PhoneDisplayCore

final class StreamHub {
    var onState: ((String) -> Void)?
    var onClientCount: ((Int) -> Void)?
    var onStats: ((Int, Int) -> Void)?
    var onLog: ((String) -> Void)?

    private let token: String
    private let synthetic: Bool
    private let stateQueue = DispatchQueue(label: "dev.phonedisplay.hub.state")

    private var server: SocketServer?
    private var helper: HelperProcess?
    private var clients: [ObjectIdentifier: SocketClient] = [:]
    private var ready: Set<ObjectIdentifier> = []
    private var headerLine: Data?
    private var cache: [Data] = []
    private var cacheBytes = 0
    private var lastCursor: Data?
    private var idleWork: DispatchWorkItem?
    private var headerTimeoutWork: DispatchWorkItem?
    private var totalFrames = 0
    private var fpsFrames = 0
    private var fpsStart = Date()
    private var stopped = false

    init(token: String, synthetic: Bool) {
        self.token = token
        self.synthetic = synthetic
    }

    func start(preferredPort: UInt16) throws -> UInt16 {
        let server = SocketServer(token: token)
        server.onLog = { [weak self] line in
            self?.stateQueue.async { self?.onLog?(line) }
        }
        server.onClientAuthenticated = { [weak self] client in
            self?.stateQueue.async { self?.add(client) }
        }
        server.onClientClosed = { [weak self] client in
            self?.stateQueue.async { self?.remove(client) }
        }
        server.onPacket = { [weak self] client, flags, payload in
            self?.stateQueue.async {
                self?.clientPacket(client, flags: flags, payload: payload)
            }
        }

        let port = try server.start(preferredPort: preferredPort)
        self.server = server
        onState?("Waiting for phone")
        return port
    }

    func stop() {
        stopped = true
        idleWork?.cancel()
        idleWork = nil
        server?.stop()
        server = nil
        closeAllClients()
        stopHelper()
    }

    private func add(_ client: SocketClient) {
        guard !stopped else {
            client.close()
            return
        }
        clients[ObjectIdentifier(client)] = client
        Diagnostics.log("client added (\(clients.count) total)")
        onClientCount?(clients.count)
        idleWork?.cancel()
        idleWork = nil

        if helper != nil {
            _ = sendHeaderAndCache(to: client)
        } else {
            startHelper()
        }
    }

    private func remove(_ client: SocketClient) {
        let id = ObjectIdentifier(client)
        guard clients.removeValue(forKey: id) != nil else { return }
        ready.remove(id)
        if client.heldButton >= 0 {
            helper?.sendInput(
                kind: 2,
                buttons: client.heldButton,
                x: client.lastX,
                y: client.lastY
            )
            client.heldButton = -1
        }
        onClientCount?(clients.count)
        if clients.isEmpty {
            scheduleIdleStop()
        }
    }

    private func startHelper() {
        guard helper == nil, !stopped else { return }
        let process = HelperProcess()
        process.onHeader = { [weak self] header in
            self?.stateQueue.async { self?.didReceiveHeader(header) }
        }
        process.onPacket = { [weak self] frame in
            self?.stateQueue.async { self?.didReceiveFrame(frame) }
        }
        process.onLog = { [weak self] line in
            self?.stateQueue.async { self?.onLog?(line) }
        }
        process.onExit = { [weak self] status in
            self?.stateQueue.async { self?.helperExited(status) }
        }

        do {
            guard let url = HelperProcess.bundledURL() else {
                throw HelperError.missing
            }
            try process.start(
                helperURL: url,
                width: 1920,
                height: 1080,
                fps: 60,
                bitrate: 10,
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
                self.closeAllClients()
            }
            headerTimeoutWork = timeout
            stateQueue.asyncAfter(deadline: .now() + 15, execute: timeout)
        } catch {
            onState?("Could not start virtual display: \(error.localizedDescription)")
            closeAllClients()
        }
    }

    private func didReceiveHeader(_ header: HelperHeader) {
        guard !stopped else { return }
        headerTimeoutWork?.cancel()
        headerTimeoutWork = nil
        headerLine = "PD01 \(header.width) \(header.height) \(header.fps) \(header.codec)\n"
            .data(using: .ascii)
        Diagnostics.log("hub header ready; clients=\(clients.count)")
        onState?("Streaming \(header.width)x\(header.height) @ \(header.fps) fps")
        for client in clients.values {
            _ = sendHeaderAndCache(to: client)
        }
    }

    private func didReceiveFrame(_ frame: HelperFrame) {
        guard !stopped else { return }
        let packet = packetData(frame)
        if frame.flags & 0x02 != 0 {
            lastCursor = packet
            broadcast(packet)
            return
        }

        if frame.flags & 0x01 != 0 {
            cache = [packet]
            cacheBytes = packet.count
        } else if !cache.isEmpty {
            cache.append(packet)
            cacheBytes += packet.count
            if cache.count > 500 || cacheBytes > (16 << 20) {
                cache = []
                cacheBytes = 0
            }
        }
        broadcast(packet)

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
        cache = []
        cacheBytes = 0
        lastCursor = nil
        onState?("Virtual display stopped (helper exit \(status))")
        closeAllClients()
    }

    private func sendHeaderAndCache(to client: SocketClient) -> Bool {
        guard let headerLine else { return false }
        let id = ObjectIdentifier(client)
        guard !ready.contains(id) else { return true }
        Diagnostics.log("sending header + \(cache.count) cached packets")
        client.send(headerLine)
        for packet in cache {
            client.send(packet)
        }
        if let lastCursor {
            client.send(lastCursor)
        }
        ready.insert(id)
        return true
    }

    private func broadcast(_ packet: Data) {
        for (id, client) in clients where ready.contains(id) {
            client.send(packet)
        }
    }

    private func clientPacket(_ client: SocketClient, flags: UInt8, payload: Data) {
        guard !stopped else { return }
        if flags & 0x04 != 0, payload.count >= 10 {
            let kind = Int(payload[0])
            let buttons = Int(payload[1] & 1)
            let x = int32BE(payload, 2)
            let y = int32BE(payload, 6)
            client.lastX = x
            client.lastY = y
            if kind == 1 {
                client.heldButton = buttons
            } else if kind == 2 {
                client.heldButton = -1
            }
            helper?.sendInput(kind: kind, buttons: buttons, x: x, y: y)
        } else if flags & 0x08 != 0, let command = payload.first {
            if command == 1, payload.count >= 2 {
                helper?.sendFps(Int(payload[1]))
            } else if command == 2 {
                helper?.requestKeyframe()
            }
        }
    }

    private func scheduleIdleStop() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.clients.isEmpty else { return }
            self.stopHelper()
            self.onState?("Waiting for phone")
        }
        idleWork = work
        stateQueue.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func stopHelper() {
        headerTimeoutWork?.cancel()
        headerTimeoutWork = nil
        helper?.onExit = nil
        helper?.stop()
        helper = nil
        headerLine = nil
        cache = []
        cacheBytes = 0
        lastCursor = nil
        ready.removeAll()
        totalFrames = 0
        fpsFrames = 0
        onStats?(0, 0)
    }

    private func closeAllClients() {
        let all = clients.values
        clients.removeAll()
        ready.removeAll()
        for client in all {
            client.close()
        }
        onClientCount?(0)
    }

    private func packetData(_ frame: HelperFrame) -> Data {
        let length = frame.payload.count
        var data = Data([
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
            frame.flags,
        ])
        data.append(frame.payload)
        return data
    }

    private func int32BE(_ data: Data, _ offset: Int) -> Int32 {
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        return Int32(bitPattern: value)
    }
}
