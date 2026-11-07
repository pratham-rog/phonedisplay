import Foundation
import PhoneDisplayCore
import Security

struct KnownDevice: Codable, Equatable {
    var id: String
    var name: String
    var secret: String
    var addedAt: Date
    var lastSeenAt: Date?
}

struct PairingWindow {
    let token: String
    let expiresAt: Date
}

final class PairingService {
    let directory: URL
    let identity: TLSIdentity
    let hostID: String
    let hostName: String
    let identityWasGenerated: Bool

    private(set) var devices: [KnownDevice]
    private(set) var pairing: PairingWindow?
    private let lock = NSRecursiveLock()

    private var devicesURL: URL { directory.appendingPathComponent("devices.json") }
    private var hostURL: URL { directory.appendingPathComponent("host.json") }
    private var identityURL: URL { directory.appendingPathComponent("identity.p12") }

    init(directory: URL? = nil) throws {
        let directory = directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.directory = directory

        let identityFile = directory.appendingPathComponent("identity.p12")
        let hostFile = directory.appendingPathComponent("host.json")
        let devicesFile = directory.appendingPathComponent("devices.json")

        let loaded = try TLSIdentity.loadOrCreate(at: identityFile)
        identity = loaded.value
        identityWasGenerated = loaded.generated

        let record = Self.loadHost(at: hostFile)
        hostID = record.id
        hostName = record.name

        if loaded.generated {
            devices = []
            try? FileManager.default.removeItem(at: devicesFile)
        } else {
            devices = Self.loadDevices(at: devicesFile)
        }
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneDisplay", isDirectory: true)
    }

    var pairingIsOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pairingIsOpenLocked
    }

    var pairingExpiry: Date? {
        lock.lock()
        defer { lock.unlock() }
        return pairingIsOpenLocked ? pairing?.expiresAt : nil
    }

    func beginPairing(host: String, port: UInt16) -> PairingPayload {
        lock.lock()
        defer { lock.unlock() }
        let token = try! Self.randomSecret(byteCount: 32)
        pairing = PairingWindow(token: token, expiresAt: Date().addingTimeInterval(120))
        return PairingPayload(
            host: host,
            port: port,
            fingerprint: identity.fingerprint,
            token: token,
            hostID: hostID,
            name: hostName
        )
    }

    func currentPayload(host: String, port: UInt16) -> PairingPayload? {
        lock.lock()
        defer { lock.unlock() }
        guard pairingIsOpenLocked, let token = pairing?.token else { return nil }
        return PairingPayload(
            host: host,
            port: port,
            fingerprint: identity.fingerprint,
            token: token,
            hostID: hostID,
            name: hostName
        )
    }

    /// Consumes the pairing token; one phone per window.
    func validatePairingToken(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pairingIsOpenLocked, let pairing else { return false }
        guard constantTimeEquals(token, pairing.token) else { return false }
        self.pairing = nil
        return true
    }

    func createDevice(name: String) -> KnownDevice {
        lock.lock()
        defer { lock.unlock() }
        let cleanName = name
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let device = KnownDevice(
            id: UUID().uuidString.lowercased(),
            name: cleanName.isEmpty ? "Android phone" : String(cleanName.prefix(64)),
            secret: try! Self.randomSecret(byteCount: 32),
            addedAt: Date(),
            lastSeenAt: nil
        )
        devices.append(device)
        if devices.count > 32 {
            devices.sort { $0.addedAt < $1.addedAt }
            devices.removeFirst(devices.count - 32)
        }
        saveDevices()
        return device
    }

    func authenticate(deviceID: String, secret: String) -> KnownDevice? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else {
            return nil
        }
        guard constantTimeEquals(secret, devices[index].secret) else {
            return nil
        }
        devices[index].lastSeenAt = Date()
        saveDevices()
        return devices[index]
    }

    func forget(deviceID: String) {
        lock.lock()
        defer { lock.unlock() }
        devices.removeAll { $0.id == deviceID }
        saveDevices()
    }

    private var pairingIsOpenLocked: Bool {
        guard let pairing else { return false }
        if Date() >= pairing.expiresAt {
            self.pairing = nil
            return false
        }
        return true
    }

    private func saveDevices() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(devices) else { return }
        try? data.write(to: devicesURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: devicesURL.path
        )
    }

    private static func loadDevices(at url: URL) -> [KnownDevice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([KnownDevice].self, from: data)) ?? []
    }

    private struct HostRecord: Codable {
        var id: String
        var name: String
    }

    private static func loadHost(at url: URL) -> HostRecord {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            if let record = try? decoder.decode(HostRecord.self, from: data) {
                return record
            }
        }
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let record = HostRecord(
            id: UUID().uuidString.lowercased(),
            name: name.components(separatedBy: .newlines).joined(separator: " ")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        return record
    }

    private static func randomSecret(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return Base64URL.encode(Data(bytes))
    }
}
