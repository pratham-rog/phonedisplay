import Foundation

public struct ConnectionInfo: Equatable {
    public let host: String
    public let port: UInt16
    public let token: String

    public init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// The string the current Android app accepts: host:port#token.
    public var connectionString: String {
        "\(host):\(port)#\(token)"
    }

    /// Forward-compatible payload for the QR scanner in the new Android app.
    public var qrPayload: String {
        let h = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
        let t = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return "phonedisplay://connect?v=1&host=\(h)&port=\(port)&token=\(t)"
    }
}
