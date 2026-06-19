import Foundation
import SwiftUI

// MARK: - 4 fáze skenu desky

enum ScanPhase: Int, CaseIterable, Codable {
    case face1 = 0   // Líce 1
    case edge1 = 1   // Hrana 1
    case face2 = 2   // Rub
    case edge2 = 3   // Hrana 2

    var displayName: String {
        switch self {
        case .face1: return "Líce 1"
        case .edge1: return "Hrana 1"
        case .face2: return "Rub"
        case .edge2: return "Hrana 2"
        }
    }

    var shortName: String {
        switch self {
        case .face1: return "L1"
        case .edge1: return "H1"
        case .face2: return "RUB"
        case .edge2: return "H2"
        }
    }

    var color: Color {
        switch self {
        case .face1: return .blue
        case .edge1: return .orange
        case .face2: return .green
        case .edge2: return .orange
        }
    }

    var next: ScanPhase? {
        ScanPhase(rawValue: rawValue + 1)
    }

    var isFace: Bool { self == .face1 || self == .face2 }
}

// MARK: - Jedna fáze (složka na disku)

struct BoardScanPhaseInfo: Codable {
    let phase: ScanPhase
    let folderName: String   // relativní k boardFolder
    var isComplete: Bool
    var frameCount: Int

    var hasStitch: Bool = false
}

// MARK: - Celý sken desky (4 fáze)

struct BoardScan: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var createdAt: Date
    var folderName: String         // Documents/boards/<folderName>
    var phases: [BoardScanPhaseInfo]

    var currentPhase: ScanPhase {
        ScanPhase(rawValue: phases.filter { $0.isComplete }.count) ?? .face1
    }

    var isComplete: Bool {
        phases.allSatisfy { $0.isComplete }
    }

    static func create(name: String) -> BoardScan {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let ts = formatter.string(from: Date())
        let folder = "board_\(ts)"
        let phases = ScanPhase.allCases.map { p in
            BoardScanPhaseInfo(phase: p, folderName: "\(p.shortName)", isComplete: false, frameCount: 0)
        }
        return BoardScan(id: UUID(), displayName: name, createdAt: Date(), folderName: folder, phases: phases)
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
        if let data = try? JSONEncoder().encode(scans) {
            try? data.write(to: storeURL)
        }
    }

    func add(_ scan: BoardScan) {
        // Vytvoří složky pro všechny fáze
        for phase in ScanPhase.allCases {
            let folder = scan.phaseFolder(phase)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        scans.insert(scan, at: 0)
        save()
    }

    func update(_ scan: BoardScan) {
        if let idx = scans.firstIndex(where: { $0.id == scan.id }) {
            scans[idx] = scan
            save()
        }
    }

    func delete(_ scan: BoardScan) {
        try? FileManager.default.removeItem(at: scan.boardFolder)
        scans.removeAll { $0.id == scan.id }
        save()
    }
}
