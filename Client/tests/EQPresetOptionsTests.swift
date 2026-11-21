import Foundation

@main
struct EQPresetOptionsTests {
    static func main() {
        let codes = [0x00, 0x30, 0x31, 0x32, 0x33, 0x20, 0xA0, 0xA1, 0xA2]
        let presets = EQPresets.options(reported: codes.map { (code: $0, name: "") }, tenBand: true)
        precondition(presets.map(\.id) == codes, "Every advertised preset must remain selectable")
        precondition(presets.map(\.name) == ["Off", "Heavy", "Clear", "Hard", "Soft", "Gaming", "Manual", "Custom 1", "Custom 2"])
        precondition(!presets.contains { $0.id == 0x10 }, "Do not substitute an unsupported legacy preset")
        let named = EQPresets.options(reported: [(code: 0x30, name: "Device-provided name")], tenBand: true)
        precondition(named[0].name == "Device-provided name", "Keep device-provided names")
        let unknown = EQPresets.options(reported: [(code: 0xB0, name: "")], tenBand: true)
        precondition(unknown[0].name == "Preset 0xB0", "Unknown IDs must not be given invented names")
        precondition(EQPresets.options(reported: [], tenBand: true).map(\.id) == [0x00, 0xA0], "Keep the conservative fallback if discovery fails")
        precondition(EQPresets.options(reported: [], tenBand: false).count == 10, "Keep the legacy preset list")
        precondition([0xA0, 0xA1, 0xA2].allSatisfy { EQPresets.isEditable($0) })
        precondition(!EQPresets.isEditable(0x30))
        print("EQ preset presentation tests passed")
    }
}
