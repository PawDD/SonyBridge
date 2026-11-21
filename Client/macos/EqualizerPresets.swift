import Foundation

struct EQPresetOption: Identifiable, Equatable {
    let id: Int
    let name: String
}

enum EQPresets {
    static let fiveBand: [(String, Int)] = [
        ("Off", 0x00), ("Bright", 0x10), ("Excited", 0x11),
        ("Mellow", 0x12), ("Relaxed", 0x13), ("Vocal", 0x14),
        ("Treble", 0x15), ("Bass", 0x16), ("Speech", 0x17),
        ("Manual", 0xA0)
    ]
    // WH-1000XM6: only Off and Manual have confirmed preset codes on the ten-band layout; its other preset
    // bytes (0x20, 0x30-0x33, 0xa1-0xa2) are unnamed, and the 5-band codes above don't apply to it.
    static let tenBand: [(String, Int)] = [("Off", 0x00), ("Manual", 0xA0)]

    static func options(reported: [(code: Int, name: String)], tenBand: Bool) -> [EQPresetOption] {
        if reported.isEmpty {
            return list(tenBand: tenBand).map { EQPresetOption(id: $0.1, name: $0.0) }
        }
        return reported.map {
            EQPresetOption(id: $0.code, name: $0.name.isEmpty ? name(for: $0.code, tenBand: tenBand) : $0.name)
        }
    }

    static func name(for code: Int, tenBand: Bool) -> String {
        if code == 0xA0 { return "Manual" }
        if let known = fiveBand.first(where: { $0.1 == code }) { return known.0 }
        switch code {
        case 0x20: return "Gaming"
        case 0x30: return "Heavy"
        case 0x31: return "Clear"
        case 0x32: return "Hard"
        case 0x33: return "Soft"
        case 0xA1: return "Custom 1"
        case 0xA2: return "Custom 2"
        default: return String(format: "Preset 0x%02X", code)
        }
    }

    static func isEditable(_ code: Int) -> Bool { [0xA0, 0xA1, 0xA2].contains(code) }

    static func list(tenBand: Bool) -> [(String, Int)] { tenBand ? Self.tenBand : fiveBand }
}
