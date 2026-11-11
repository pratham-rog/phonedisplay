import Foundation
import PhoneDisplayCore
import Security

enum TLSIdentityError: LocalizedError {
    case opensslMissing
    case opensslFailed(String)
    case importFailed(OSStatus)
    case certificateMissing

    var errorDescription: String? {
        switch self {
        case .opensslMissing:
            return "The system OpenSSL tool is missing."
        case .opensslFailed(let message):
            return "Could not create the TLS identity: \(message)"
        case .importFailed(let status):
            return "Could not load the TLS identity (error \(status))."
        case .certificateMissing:
            return "The TLS identity has no certificate."
        }
    }
}

struct LoadedIdentity {
    let value: TLSIdentity
    let generated: Bool
}

final class TLSIdentity {
    private static let passphrase = "phonedisplay-local"

    let identity: SecIdentity
    let certificate: SecCertificate
    let fingerprint: String

    private init(identity: SecIdentity, certificate: SecCertificate, fingerprint: String) {
        self.identity = identity
        self.certificate = certificate
        self.fingerprint = fingerprint
    }

    static func loadOrCreate(at url: URL) throws -> LoadedIdentity {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return LoadedIdentity(value: try load(at: url), generated: false)
            } catch {
                Diagnostics.log("TLS identity unreadable; regenerating")
                try? FileManager.default.removeItem(at: url)
            }
        }
        return LoadedIdentity(value: try generate(at: url), generated: true)
    }

    private static func load(at url: URL) throws -> TLSIdentity {
        let data = try Data(contentsOf: url)
        return try importPKCS12(data)
    }

    private static func importPKCS12(_ data: Data) throws -> TLSIdentity {
        var items: CFArray?
        var options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
        ]
        if #available(macOS 15.0, *) {
            // Keep the identity in memory. Importing it into the login keychain
            // makes macOS prompt for the login password when TLS uses the key.
            options[kSecImportToMemoryOnly as String] = true
        } else {
            // macOS 14 has no memory-only import. Give the imported key an ACL
            // that trusts this app, so TLS does not prompt for the login keychain.
            options[kSecImportExportAccess as String] = try importAccess()
        }
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw TLSIdentityError.importFailed(status)
        }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let rawIdentity = first[kSecImportItemIdentity as String]
        else {
            throw TLSIdentityError.importFailed(status)
        }
        let identity = rawIdentity as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate
        else {
            throw TLSIdentityError.certificateMissing
        }
        let der = SecCertificateCopyData(certificate) as Data
        return TLSIdentity(
            identity: identity,
            certificate: certificate,
            fingerprint: sha256Hex(der)
        )
    }

    /// macOS 14 fallback: import the key with an ACL that trusts this app.
    private static func importAccess() throws -> SecAccess {
        var app: SecTrustedApplication?
        let appStatus = SecTrustedApplicationCreateFromPath(nil, &app)
        guard appStatus == errSecSuccess, let app else {
            throw TLSIdentityError.importFailed(appStatus)
        }
        var access: SecAccess?
        let status = SecAccessCreate(
            "SpareScreen TLS" as CFString,
            [app] as CFArray,
            &access
        )
        guard status == errSecSuccess, let access else {
            throw TLSIdentityError.importFailed(status)
        }
        return access
    }

    private static func generate(at url: URL) throws -> TLSIdentity {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: openssl.path) else {
            throw TLSIdentityError.opensslMissing
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent("identity.tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        // shortcut: openssl CLI for first-run P-256 identity; replace with native
        // key/cert generation if /usr/bin/openssl ever stops shipping.
        try run(openssl, [
            "ecparam", "-name", "prime256v1", "-genkey", "-noout",
            "-out", temporary.appendingPathComponent("key.pem").path,
        ])
        try run(openssl, [
            "req", "-new", "-x509",
            "-key", temporary.appendingPathComponent("key.pem").path,
            "-out", temporary.appendingPathComponent("cert.pem").path,
            "-days", "3650",
            "-subj", "/CN=SpareScreen",
        ])
        let p12 = temporary.appendingPathComponent("identity.p12")
        try run(openssl, [
            "pkcs12", "-export",
            "-inkey", temporary.appendingPathComponent("key.pem").path,
            "-in", temporary.appendingPathComponent("cert.pem").path,
            "-out", p12.path,
            "-passout", "pass:\(passphrase)",
        ])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: p12.path
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: p12, to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return try importPKCS12(try Data(contentsOf: url))
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TLSIdentityError.opensslFailed(message)
        }
    }
}
