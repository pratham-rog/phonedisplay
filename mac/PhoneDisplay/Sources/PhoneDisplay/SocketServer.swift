import Darwin
import Foundation
import PhoneDisplayCore

final class SocketClient {
    let fd: Int32
    var onClose: (() -> Void)?
    var heldButton = -1
    var lastX: Int32 = 0
    var lastY: Int32 = 0

    private let sendQueue = DispatchQueue(label: "dev.phonedisplay.client.send")
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            let result: Int = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return 0 }
                var sent = 0
                while sent < buffer.count {
                    let written = Darwin.send(
                        self.fd,
                        base.advanced(by: sent),
                        buffer.count - sent,
                        0
                    )
                    if written <= 0 {
                        return written
                    }
                    sent += written
                }
                return sent
            }
            if result <= 0 {
                self.close()
            }
        }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        onClose?()
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

final class SocketServer {
    var onClientAuthenticated: ((SocketClient) -> Void)?
    var onClientClosed: ((SocketClient) -> Void)?
    var onPacket: ((SocketClient, UInt8, Data) -> Void)?
    var onLog: ((String) -> Void)?

    private let token: String
    private let acceptQueue = DispatchQueue(label: "dev.phonedisplay.server.accept")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(token: String) {
        self.token = token
    }

    func start(preferredPort: UInt16) throws -> UInt16 {
        for candidate in preferredPort..<(preferredPort + 20) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw POSIXError(.ENFILE)
            }
            setOption(fd, SO_REUSEADDR, 1)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 16) == 0 else {
                Darwin.close(fd)
                continue
            }

            listenFD = fd
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else {
                Darwin.close(fd)
                listenFD = -1
                continue
            }

            let actualPort = actual.sin_port.bigEndian
            let readSource = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: acceptQueue
            )
            readSource.setEventHandler { [weak self] in
                self?.acceptPending()
            }
            readSource.resume()
            source = readSource
            return actualPort
        }
        throw POSIXError(.EADDRINUSE)
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                return
            }
            setOption(fd, SO_NOSIGPIPE, 1)
            let client = SocketClient(fd: fd)
            client.onClose = { [weak self, weak client] in
                guard let client else { return }
                self?.onClientClosed?(client)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ client: SocketClient) {
        defer { client.close() }
        setReceiveTimeout(client.fd, seconds: 5)
        guard let greeting = readGreeting(client.fd) else {
            onLog?("Client sent no greeting.")
            return
        }
        let parts = greeting.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0] == "PD01",
              constantTimeEquals(parts[1], token)
        else {
            Diagnostics.log("client rejected: bad token")
            onLog?("Client rejected: bad token.")
            return
        }

        setReceiveTimeout(client.fd, seconds: 0)
        Diagnostics.log("client authenticated")
        onClientAuthenticated?(client)

        while true {
            guard let header = readExactly(client.fd, count: 5) else { return }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            let flags = header[4]
            guard length > 0, length <= 8 << 20,
                  let payload = readExactly(client.fd, count: Int(length))
            else {
                return
            }
            onPacket?(client, flags, payload)
        }
    }

    private func readGreeting(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 512 {
            var byte: UInt8 = 0
            let count = read(fd, &byte, 1)
            if count <= 0 {
                return nil
            }
            if byte == 0x0A {
                return String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
            }
            bytes.append(byte)
        }
        return nil
    }

    private func readExactly(_ fd: Int32, count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return read(fd, base.advanced(by: offset), count - offset)
            }
            if received < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if received == 0 {
                return nil
            }
            offset += received
        }
        return Data(bytes)
    }

    private func setOption(_ fd: Int32, _ name: Int32, _ value: Int32) {
        var value = value
        setsockopt(fd, SOL_SOCKET, name, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    private func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval()
        timeout.tv_sec = seconds
        timeout.tv_usec = 0
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
}
