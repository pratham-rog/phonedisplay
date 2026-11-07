import Foundation

enum DisplayProfile: String, CaseIterable, Identifiable {
    case universal
    case galaxyS24

    var id: String { rawValue }

    var title: String {
        switch self {
        case .universal: return "Universal — 1920×1080 at 60 fps"
        case .galaxyS24: return "Galaxy S24 — 3120×1440 at 90 fps"
        }
    }

    var detail: String {
        switch self {
        case .universal:
            return "Works with every supported Android phone. Uses about 10 Mbps."
        case .galaxyS24:
            return "Sharper and smoother on a Galaxy S24-class 1440p 90 Hz phone. Uses about 20 Mbps."
        }
    }

    var width: Int {
        switch self {
        case .universal: return 1920
        case .galaxyS24: return 3120
        }
    }

    var height: Int {
        switch self {
        case .universal: return 1080
        case .galaxyS24: return 1440
        }
    }

    var fps: Int {
        switch self {
        case .universal: return 60
        case .galaxyS24: return 90
        }
    }

    var bitrate: Int {
        switch self {
        case .universal: return 10
        case .galaxyS24: return 20
        }
    }
}
