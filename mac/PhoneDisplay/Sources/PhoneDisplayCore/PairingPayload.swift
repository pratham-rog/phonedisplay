import CryptoKit
import Foundation

public struct PairingPayload: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let fingerprint: String
    public let token: String
    public let hostID: String
    public let name: String

    public init(
        host: String,
        port: UInt16,
        fingerprint: String,
        token: String,
        hostID: String,
        name: String
    ) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.token = token
        self.hostID = hostID
        self.name = name
    }

    public var url: String {
        var components = URLComponents()
        components.scheme = "phonedisplay"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: fingerprint),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "id", value: hostID),
            URLQueryItem(name: "name", value: name),
        ]
        return components.string ?? ""
    }

    public init?(url: String) {
        guard let components = URLComponents(string: url),
              components.scheme == "phonedisplay",
              components.host == "pair"
        else {
            return nil
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        guard values["v"] == "1",
              let host = values["host"], !host.isEmpty,
              let portText = values["port"], let port = UInt16(portText), port > 0,
              let fingerprint = values["fp"], !fingerprint.isEmpty,
              let token = values["token"], !token.isEmpty,
              let hostID = values["id"], !hostID.isEmpty,
              let name = values["name"], !name.isEmpty
        else {
            return nil
        }
        self.init(
            host: host,
            port: port,
            fingerprint: fingerprint,
            token: token,
            hostID: hostID,
            name: name
        )
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 {
            value.append("=")
        }
        return Data(base64Encoded: value)
    }
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
