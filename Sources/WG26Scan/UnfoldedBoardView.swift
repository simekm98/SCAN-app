import SwiftUI

/// Zobrazí 4 stitched plochy vedle sebe jako rozložená deska.
/// Všechny pásy jsou zarovnané na stejné ose délky (X) → suky se dají párovat.
///
/// Rozložení (shora dolů):
///   Hrana 1 (narrow)
///   Líce 1  (wide)
///   Hrana 2 (narrow)
///   Rub     (wide)
struct UnfoldedBoardView: View {
    let scan: BoardScan
    @Environment(\.dismiss) private var dismiss

    // Pořadí pro rozložení cross-section
    private let layoutOrder: [ScanPhase] = [.edge1, .face1, .edge2, .face2]

    var body: some View {
        NavigationView {
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 2) {
                    ForEach(layoutOrder, id: \.self) { phase in
                        phaseStrip(phase)
                    }
                }
                .padding(8)
            }
            .background(Color.black)
            .navigationTitle(scan.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        items: layoutOrder.compactMap { p -> URL? in
                            scan.hasStitch(p) ? scan.stitchURL(p) : nil
                        }
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func phaseStrip(_ phase: ScanPhase) -> some View {
        let url = scan.stitchURL(phase)
        if scan.hasStitch(phase),
           let img = UIImage(contentsOfFile: url.path) {

            let h = phase.isFace ? 200.0 : 60.0   // px výška pásů ve view

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(phase.displayName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(phase.color)
                        .frame(width: 48)
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(phase.color.opacity(0.4))
                }
                .padding(.bottom, 2)

                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: h)
                    .clipped()
                    .overlay(
                        Rectangle()
                            .stroke(phase.color.opacity(0.6), lineWidth: 1)
                    )
            }
        } else {
            HStack {
                Text(phase.displayName)
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("– mozaika chybí")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.6))
            }
            .frame(height: 44)
        }
    }
}
