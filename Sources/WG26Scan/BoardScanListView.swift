import SwiftUI

struct BoardScanListView: View {
    @ObservedObject var store: BoardScanStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedScan: BoardScan? = nil
    @State private var showUnfolded = false
    @State private var deleteTarget: BoardScan? = nil
    @State private var phaseImage: UIImage? = nil
    @State private var phaseImageTitle = ""
    @State private var showPhaseImage = false

    var body: some View {
        NavigationView {
            List {
                ForEach(store.scans) { scan in
                    boardRow(scan)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Skeny desek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Obnovit") { store.load() }
                }
            }
        }
        .sheet(isPresented: $showUnfolded) {
            if let scan = selectedScan { UnfoldedBoardView(scan: scan) }
        }
        .sheet(isPresented: $showPhaseImage) {
            if let img = phaseImage {
                PhaseImageView(image: img, title: phaseImageTitle)
            }
        }
        .alert("Smazat sken?",
               isPresented: Binding(get: { deleteTarget != nil },
                                    set: { if !$0 { deleteTarget = nil } })) {
            Button("Smazat", role: .destructive) {
                if let s = deleteTarget { store.delete(s) }
                deleteTarget = nil
            }
            Button("Zrušit", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Smažou se všechna data pro \"\(deleteTarget?.displayName ?? "")\".")
        }
    }

    private func boardRow(_ scan: BoardScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Název + datum
            HStack {
                Text(scan.displayName).font(.headline)
                Spacer()
                Text(scan.createdAt, style: .date).font(.caption).foregroundColor(.secondary)
            }

            // Fáze indikátory
            HStack(spacing: 8) {
                ForEach(ScanPhase.allCases, id: \.self) { phase in
                    let info = scan.phases[phase.rawValue]
                    VStack(spacing: 2) {
                        Image(systemName: info.isComplete ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(info.isComplete ? phase.color : .gray)
                        Text(phase.shortName).font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                Spacer()

                if scan.isComplete {
                    Button {
                        selectedScan = scan
                        showUnfolded = true
                    } label: {
                        Label("Deska", systemImage: "rectangle.3.group")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                }

                Button(role: .destructive) { deleteTarget = scan } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.bordered).tint(.red)
            }

            // Miniaturní náhledy – ťuknutím zobrazit plný náhled
            if scan.phases.contains(where: { $0.hasStitch }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ScanPhase.allCases, id: \.self) { phase in
                            if scan.hasStitch(phase),
                               let img = UIImage(contentsOfFile: scan.stitchURL(phase).path) {
                                Button {
                                    phaseImage = img
                                    phaseImageTitle = "\(scan.displayName) – \(phase.displayName)"
                                    showPhaseImage = true
                                } label: {
                                    VStack(spacing: 2) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 90, height: phase.isFace ? 45 : 18)
                                            .clipped()
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(phase.color.opacity(0.7), lineWidth: 1.5)
                                            )
                                        Text(phase.shortName)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(phase.color)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
