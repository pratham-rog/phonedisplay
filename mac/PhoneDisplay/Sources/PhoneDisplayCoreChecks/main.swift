import Foundation
import PhoneDisplayCore

var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    precondition(condition(), "FAIL: \(name)")
    print("  [PASS] \(name)")
}

// Parser: split header and frames.
var parser = HelperStreamParser()
check(
    parser.append(Data("PDH1 1920 1080 60 h264 42\n".utf8)) ==
        [.header(HelperHeader(width: 1920, height: 1080, fps: 60, codec: "h264", displayID: 42))],
    "parses helper header"
)

var frame = Data([0, 0, 0, 3, 1])
frame.append(contentsOf: [9, 8, 7])
check(parser.append(frame.prefix(2)).isEmpty, "waits for a split frame header")
check(
    parser.append(frame.dropFirst(2)) ==
        [.packet(HelperFrame(flags: 1, payload: Data([9, 8, 7])))],
    "parses a split frame"
)

var cursor = Data([0, 0, 0, 2, 2, 1, 2])
check(parser.append(cursor.prefix(4)).isEmpty, "waits for a split cursor packet")
cursor.removeFirst(4)
check(
    parser.append(cursor) ==
        [.packet(HelperFrame(flags: 2, payload: Data([1, 2])))],
    "parses a cursor packet"
)

var badParser = HelperStreamParser()
check(
    badParser.append(Data("nope\n".utf8)) ==
        [.error("Unexpected helper header: nope")],
    "rejects a bad helper header"
)

var hugeParser = HelperStreamParser()
_ = hugeParser.append(Data("PDH1 1920 1080 60 h264\n".utf8))
check(
    hugeParser.append(Data([0x02, 0x00, 0x00, 0x01, 0])) ==
        [.error("Invalid helper frame length: 33554433")],
    "rejects an oversized frame"
)

// Token: creates a private file and reuses the value.
let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let tokenURL = directory.appendingPathComponent("token")
let token = try TokenStore.loadOrCreate(at: tokenURL)
let reused = try TokenStore.loadOrCreate(at: tokenURL)
check(token.count == 32, "creates a 32-character token")
check(reused == token, "reuses the token")
let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
check(attributes[.posixPermissions] as? Int == 0o600, "token file is 0600")

check(constantTimeEquals("abc", "abc"), "constant-time equal strings")
check(!constantTimeEquals("abc", "abd"), "constant-time different strings")
check(!constantTimeEquals("abc", "ab"), "constant-time different lengths")

// Connection string / QR payload.
let info = ConnectionInfo(host: "10.0.0.2", port: 8420, token: "a_b-c")
check(info.connectionString == "10.0.0.2:8420#a_b-c", "connection string")
check(
    info.qrPayload ==
        "phonedisplay://connect?v=1&host=10.0.0.2&port=8420&token=a_b-c",
    "QR payload"
)

// Pairing payload round-trip.
let pairing = PairingPayload(
    host: "10.0.0.2",
    port: 8420,
    fingerprint: "abc123",
    token: "pair_token",
    hostID: "host-uuid",
    name: "Pixiii's Mac"
)
let parsed = PairingPayload(url: pairing.url)
check(parsed == pairing, "pairing payload round-trip")
check(pairing.url.hasPrefix("phonedisplay://pair?v=1&"), "pairing URL scheme")
check(PairingPayload(url: "phonedisplay://pair?v=2") == nil, "rejects wrong pairing version")
check(PairingPayload(url: "https://example.com") == nil, "rejects wrong pairing scheme")

// Base64url is the on-wire secret format.
let bytes = Data([0x00, 0xFF, 0x10, 0x20, 0x30])
let encoded = Base64URL.encode(bytes)
check(Base64URL.decode(encoded) == bytes, "base64url round-trip")
check(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="), "base64url alphabet")

check(
    sha256Hex(Data()) ==
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "SHA-256 empty vector"
)

print("\n\(checks) checks passed.")
