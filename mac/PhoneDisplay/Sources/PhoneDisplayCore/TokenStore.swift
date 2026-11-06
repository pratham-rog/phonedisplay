import Foundation
import Security

public enum TokenStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".phonedisplay-token")
    }

    /// Loads the existing token or creates a 24-byte base64url token at 0600.
    public static func loadOrCreate(at url: URL) throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .ascii)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return existing
        }

        let token = try randomToken()
        let data = Data((token + "\n").utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let left = Array(a.utf8)
    let right = Array(b.utf8)
    var difference = UInt8(left.count == right.count ? 0 : 1)
    let count = max(left.count, right.count)
    for index in 0..<count {
        let l = index < left.count ? left[index] : 0
        let r = index < right.count ? right[index] : 0
        difference |= l ^ r
    }
    return difference == 0
}
