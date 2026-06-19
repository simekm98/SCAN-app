import Foundation
import SwiftUI

// MARK: - Fáze skenu dle průřezu desky (pohled z čela)
// Pořadí: A → C → B → D
// A = horní plocha (wide), C = spodní plocha (wide) → nejdříve
// B = levá hrana (narrow), D = pravá hrana (narrow) → po snížení stojanů

enum ScanPhase: Int, CaseIterable, Codable {
    case faceA = 0   // Plocha A – horní (wide)
    case faceC = 1   // Plocha C – spodní (wide)
    case edgeB = 2   // Hrana B – levá (narrow)
    case edgeD = 3   // Hrana D – pravá (narrow)

    var displayName: String {
        switch self {
        case .faceA: return "Plocha A"
        case .faceC: return "Plocha C"
        case .edgeB: return "Hrana B"
        case .edgeD: return "Hrana D"
        }
    }

    var shortName: String {
        switch self {
        case .faceA: return "A"
        case .faceC: return "C"
        case .edgeB: return "B"
        case .edgeD: return "D"
        }
    }

    var color: Color {
        switch self {
        case .faceA: return .blue
        case .faceC: return .green
        case .edgeB: return .orange
        case .edgeD: return .purple
        }
    }

    var isFace: Bool { self == .faceA || self == .faceC }

    var next: ScanPhase? { ScanPhase(rawValue: rawValue + 1) }

    var groupLabel: String {
        isFace ? "Plocha" : "Hrana"
    }
}

// MARK: - Jedna fáze

struct BoardScanPhaseInfo: Codable {
    let phase: ScanPhase
    let folderName: String
    var isComplete: Bool
    var frameCount: Int
    var hasStitch: Bool
}

// MARK: - Celý sken desky

struct BoardScan: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var createdAt: Date
    var folderName: String
    var phases: [BoardScanPhaseInfo]

    var currentPhase: ScanPhase {
        ScanPhase(rawValue: phases.filter { $0.isComplete }.count) ?? .faceA
    }

    var isComplete: Bool { phases.allSatisfy { $0.isComplete } }

    static func create(name: String) -> BoardScan {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let folder = "board_\(formatter.string(from: Date()))"
        let phases = ScanPhase.allCases.map {
            BoardScanPhaseInfo(phase: $0, folderName: $0.shortName,
                               isComplete: false, frameCount: 0, hasStitch: false)
        }
        return BoardScan(id: UUID(), displayName: name, createdAt: Date(),
                         folderName: folder, phases: phases)
    }

    var boardFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("boards/\(folderName)", isDirectory: true)
    }

    func phaseFolder(_ phase: ScanPhase) -> URL {
        boardFolder.appendingPathComponent(phases[phase.rawValue].folderName, isDirectory: true)
    }

    func stitchURL(_ phase: ScanPhase) -> URL {
        phaseFolder(phase).appendingPathComponent("mozaika.png")
    }

    func hasStitch(_ phase: ScanPhase) -> Bool {
        FileManager.default.fileExists(atPath: stitchURL(phase).path)
    }
}

// MARK: - Persistence

final class BoardScanStore: ObservableObject {
    @Published var scans: [BoardScan] = []

    private var storeURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("boards/index.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let loaded = try? JSONDecoder().decode([BoardScan].self, from: data) else { return }
        scans = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func save() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(scans) { try? data.write(to: storeURL) }
    }

    func add(_ scan: BoardScan) {
        for phase in ScanPhase.allCases {
            try? FileManager.default.createDirectory(at: scan.phaseFolder(phase),
                                                     withIntermediateDirectories: true)
        }
        scans.insert(scan, at: 0)
        save()
    }

    func update(_ scan: BoardScan) {
        if let idx = scans.firstIndex(where: { $0.id == scan.id }) {
            scans[idx] = scan; save()
        }
    }

    func delete(_ scan: BoardScan) {
        try? FileManager.default.removeItem(at: scan.boardFolder)
        scans.removeAll { $0.id == scan.id }
        save()
    }
}
