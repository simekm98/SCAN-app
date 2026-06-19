import SwiftUI

/// Seznam všech skenů desek – surová data i spojená mozaika, možnost mazat.
struct BoardScanListView: View {
    @ObservedObject var store: BoardScanStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScan: BoardScan? = nil
    @State private var showUnfolded = false
    @State private var deleteTarget: BoardScan? = nil

    var body: some View {
        NavigationView {
            List {
                ForEach(store.scans) { scan in
                    boardScanRow(scan)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Skeny desek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showUnfolded) {
            if let scan = selectedScan { UnfoldedBoardView(scan: scan) }
        }
        .alert("Smazat sken?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Smazat", role: .destructive) {
                if let s = deleteTarget { store.delete(s) }
                deleteTarget = nil
            }
            Button("Zrušit", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Smažou se všechny snímky a mozaiky pro \"\(deleteTarget?.displayName ?? "")\".")
        }
    }

    private func boardScanRow(_ scan: BoardScan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Název + datum
            HStack {
                Text(scan.displayName).font(.headline)
                Spacer()
                Text(scan.createdAt, style: .date).font(.caption).foregroundColor(.secondary)
            }

            // Fáze – čtyři indikátory
            HStack(spacing: 6) {
                ForEach(ScanPhase.allCases, id: \.self) { phase in
                    let info = scan.phases[phase.rawValue]
                    VStack(spacing: 2) {
                        Image(systemName: info.isComplete ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(info.isComplete ? phase.color : .gray)
                            .font(.caption)
                        Text(phase.shortName).font(.system(size: 9)).foregroundColor(.secondary)
                        if info.isComplete {
                            Text("\(info.frameCount) fr").font(.system(size: 8)).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()

                // Akce
                if scan.isComplete {
                    Button {
                        selectedScan = scan
                        showUnfolded = true
                    } label: {
                        Label("Deska", systemImage: "rectangle.stack")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                Button(role: .destructive) { deleteTarget = scan } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            // Miniaturní náhledy mozaik
            if scan.phases.contains(where: { $0.hasStitch }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ScanPhase.allCases, id: \.self) { phase in
                            if scan.hasStitch(phase),
                               let img = UIImage(contentsOfFile: scan.stitchURL(phase).path) {
                                VStack(spacing: 2) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: phase.isFace ? 40 : 15)
                                        .clipped()
                                        .cornerRadius(3)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3)
                                                .stroke(phase.color.opacity(0.6), lineWidth: 1)
                                        )
                                    Text(phase.shortName)
                                        .font(.system(size: 8))
                                        .foregroundColor(phase.color)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
