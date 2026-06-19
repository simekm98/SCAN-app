import Foundation

// MARK: - Mód vzorkování

enum CaptureMode: String, CaseIterable {
    case spatial  = "Prostorový (mm)"
    case temporal = "Časový (Hz)"
}

// MARK: - Podmínka ukončení skenu

enum StopCondition {
    case manual
    case distance(mm: Float)   // zastav po ujetí N mm
    case frameCount(Int)       // zastav po N snímcích
}

// MARK: - Rychlost závěrky (jako zlomek)

struct ShutterSpeed: Identifiable, Equatable {
    let id = UUID()
    let seconds: Double
    let display: String   // "1/500"

    static let presets: [ShutterSpeed] = [
        ShutterSpeed(seconds: 1/4000, display: "1/4000"),
        ShutterSpeed(seconds: 1/2000, display: "1/2000"),
        ShutterSpeed(seconds: 1/1000, display: "1/1000"),
        ShutterSpeed(seconds: 1/500,  display: "1/500"),
        ShutterSpeed(seconds: 1/250,  display: "1/250"),
        ShutterSpeed(seconds: 1/125,  display: "1/125"),
        ShutterSpeed(seconds: 1/60,   display: "1/60"),
        ShutterSpeed(seconds: 1/30,   display: "1/30"),
        ShutterSpeed(seconds: 1/15,   display: "1/15"),
        ShutterSpeed(seconds: 1/8,    display: "1/8"),
        ShutterSpeed(seconds: 1/4,    display: "1/4"),
    ]
}

// MARK: - Zoom / Objektiv

enum LensType: String, CaseIterable {
    case ultrawide = "0.5×"
    case wide      = "1×"
    case tele2x    = "2×"
    case tele3x    = "3×"

    var zoomFactor: CGFloat {
        switch self {
        case .ultrawide: return 0.5
        case .wide:      return 1.0
        case .tele2x:    return 2.0
        case .tele3x:    return 3.0
        }
    }
}

// MARK: - Aktivní parametr v overlay

enum ActiveParam {
    case none, iso, shutter, focus, lens, stopCondition
}

// MARK: - Hlasové povely

enum VoiceCommand: String {
    case start      = "start"
    case stop       = "stop"
    case lock       = "zamknout"
    case unlock     = "odemknout"
    case unknown
}
