import Darwin
import Foundation

public enum LANAddress {
    /// Best-effort IPv4 address the phone should dial. Prefers Wi-Fi/Ethernet.
    public static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return nil
        }
        defer { freeifaddrs(list) }

        var candidates: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else {
                continue
            }
            candidates.append((String(cString: entry.pointee.ifa_name), ip))
        }

        for name in ["en0", "en1", "bridge0"] {
            if let match = candidates.first(where: { $0.name == name }) {
                return match.address
            }
        }
        return candidates.first?.address
    }
}
