import SwiftUI

/// Wrapper pro URL aby bylo Identifiable (potřebuje .sheet)
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct ScanListView: View {
    @State private var scans: [URL] = []
    @State private var selectedForStitch: IdentifiableURL? = nil
    @State private var stitching = false
    @State private var progress: Double = 0
    @State private var progressMsg = ""
    @State private var result: StitchResult? = nil
    @State private var stitchFolder: URL? = nil
    @State private var error: String? = nil
    @State private var pxPerMM: Double = 10.0
    @State private var showScanner = false
    @State private var showResult = false

    var body: some View {
        NavigationView {
            VStack {
                if scans.isEmpty {
                    emptyState
                } else {
                    List(scans, id: \.self) { scan in
                        scanRow(scan)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("WoodScanner")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showScanner = true } label: {
                        Image(systemName: "camera.fill")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Obnovit") { loadScans() }
                }
            }
        }
        .onAppear { loadScans() }
        .fullScreenCover(isPresented: $showScanner, onDismiss: loadScans) {
            ARScanView()
        }
        .sheet(item: $selectedForStitch) { wrap in
            StitchSetupView(
                scanFolder: wrap.url,
                pxPerMM: $pxPerMM,
                onStitch: { runStitch(folder: wrap.url) }
            )
        }
        .sheet(isPresented: $showResult) {
            if let res = result, let folder = stitchFolder {
                StitchResultView(result: res, scanFolder: folder)
            }
        }
        .overlay {
            if stitching { stitchingOverlay }
        }
        .alert("Chyba stitchingu",
               isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext").font(.system(size: 48)).foregroundColor(.gray)
            Text("Zatím žádné skeny").foregroundColor(.gray)
            Button("Spustit skenování") { showScanner = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    private func scanRow(_ scan: URL) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(scan.lastPathComponent).font(.subheadline)
                if let info = scanInfo(scan) {
                    Text(info).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if FileManager.default.fileExists(atPath: scan.appendingPathComponent("mozaika.png").path) {
                Image(systemName: "photo.on.rectangle").foregroundColor(.green)
            }
            Button("Stitch") { selectedForStitch = IdentifiableURL(scan) }
                .buttonStyle(.bordered)
        }
    }

    private var stitchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 250)
                Text(progressMsg).font(.caption).foregroundColor(.white)
                Text("\(Int(progress * 100)) %").font(.headline).foregroundColor(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    private func loadScans() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        scans = ((try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("scan_") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func scanInfo(_ url: URL) -> String? {
        let meta = url.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: meta),
              let m = try? JSONDecoder().decode(ScanMetadata.self, from: data) else { return nil }
        return "\(m.totalFrames) snímků • krok \(String(format: "%.0f", m.stepMM)) mm"
    }

    private func runStitch(folder: URL) {
        stitching = true; progress = 0; progressMsg = "Spouštím…"
        let engine = StitchingEngine()
        engine.pxPerMM = Float(pxPerMM)
        engine.progressHandler = { p, msg in progress = p; progressMsg = msg }
        Task {
            do {
                let res = try await engine.stitch(scanFolder: folder)
                stitching = false; result = res; stitchFolder = folder
                showResult = true; loadScans()
            } catch {
                stitching = false; self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - StitchSetupView

struct StitchSetupView: View {
    let scanFolder: URL
    @Binding var pxPerMM: Double
    let onStitch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Rozlišení mozaiky") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("px/mm:")
                            Spacer()
                            Text(String(format: "%.0f px/mm", pxPerMM)).monospacedDigit().foregroundColor(.secondary)
                        }
                        Slider(value: $pxPerMM, in: 2...30, step: 1)
                        HStack {
                            ForEach([5.0, 10.0, 15.0, 20.0], id: \.self) { v in
                                Button("\(Int(v))") { pxPerMM = v }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                        Text("Odh. velikost: ~\(estSizeMB) MB").font(.caption).foregroundColor(.secondary)
                    }
                }
                Section { Text(scanFolder.lastPathComponent).font(.caption).foregroundColor(.secondary) }
            }
            .navigationTitle("Nastavení stitchingu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušit") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spustit") { dismiss(); onStitch() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var estSizeMB: String {
        let mb = 300.0 * 4000.0 * pxPerMM * pxPerMM * 3 / 1_048_576.0
        return String(format: "%.0f", mb)
    }
}

// MARK: - StitchResultView

struct StitchResultView: View {
    let result: StitchResult
    let scanFolder: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: result.image).resizable().scaledToFit().frame(minWidth: 300)
            }
            .navigationTitle("Mozaika")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zavřít") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: scanFolder.appendingPathComponent("mozaika.png"),
                        preview: SharePreview("Mozaika desky")
                    ) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label("\(Int(result.widthMM)) × \(Int(result.heightMM)) mm", systemImage: "ruler")
                    Spacer()
                    Text("\(Int(result.image.size.width))×\(Int(result.image.size.height)) px")
                }
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
    }
}
