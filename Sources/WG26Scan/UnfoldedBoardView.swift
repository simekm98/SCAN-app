import SwiftUI
import UIKit

// MARK: - Zoomovatelný UIScrollView wrapper

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 0.2
        scrollView.maximumZoomScale = 12.0
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scrollView.addSubview(imageView)
        scrollView.contentSize = imageView.intrinsicContentSize

        // Fit to screen
        DispatchQueue.main.async {
            let sw = scrollView.bounds.width
            let sh = scrollView.bounds.height
            let iw = imageView.intrinsicContentSize.width
            let ih = imageView.intrinsicContentSize.height
            if iw > 0 && ih > 0 {
                let scale = min(sw / iw, sh / ih)
                scrollView.minimumZoomScale = max(0.05, scale * 0.5)
                scrollView.zoomScale = scale
                // Center
                let ox = max(0, (sw - iw * scale) / 2)
                let oy = max(0, (sh - ih * scale) / 2)
                scrollView.contentInset = UIEdgeInsets(top: oy, left: ox, bottom: oy, right: ox)
            }
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.subviews.first
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let img = scrollView.subviews.first else { return }
            let sw = scrollView.bounds.width
            let sh = scrollView.bounds.height
            let ox = max(0, (sw - img.frame.width)  / 2)
            let oy = max(0, (sh - img.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: oy, left: ox, bottom: oy, right: ox)
        }
    }
}

// MARK: - Sestavení finálního obrázku (A nad C, B a D jako pásy)

func buildUnfoldedImage(scan: BoardScan) -> UIImage? {
    // Pořadí ve složeném obrázku: A (nahoře), B, C, D
    let order: [ScanPhase] = [.faceA, .edgeB, .faceC, .edgeD]

    var strips: [(UIImage, ScanPhase)] = []
    for phase in order {
        if scan.hasStitch(phase),
           let img = UIImage(contentsOfFile: scan.stitchURL(phase).path) {
            strips.append((img, phase))
        }
    }
    guard !strips.isEmpty else { return nil }

    let targetWidth = strips.map { $0.0.size.width }.max() ?? 1000
    var totalHeight: CGFloat = 0
    var scaledStrips: [(UIImage, ScanPhase, CGFloat)] = []  // image, phase, scaledH

    for (img, phase) in strips {
        let scale = targetWidth / img.size.width
        let h = img.size.height * scale
        scaledStrips.append((img, phase, h))
        totalHeight += h + 4  // 4px separator
    }
    totalHeight = max(1, totalHeight)

    let size = CGSize(width: targetWidth, height: totalHeight)
    UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
    defer { UIGraphicsEndImageContext() }

    UIColor.black.setFill()
    UIRectFill(CGRect(origin: .zero, size: size))

    var y: CGFloat = 0
    for (img, phase, h) in scaledStrips {
        // Label nad pruhem
        let labelRect = CGRect(x: 4, y: y + 2, width: 60, height: 18)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 14),
            .foregroundColor: UIColor.white.withAlphaComponent(0.8)
        ]
        NSString(string: phase.shortName).draw(in: labelRect, withAttributes: attrs)

        let drawRect = CGRect(x: 0, y: y, width: targetWidth, height: h)
        img.draw(in: drawRect)
        y += h + 4
    }

    return UIGraphicsGetImageFromCurrentImageContext()
}

// MARK: - Hlavní View

struct UnfoldedBoardView: View {
    let scan: BoardScan
    @Environment(\.dismiss) private var dismiss
    @State private var compositeImage: UIImage? = nil

    var body: some View {
        NavigationView {
            Group {
                if let img = compositeImage {
                    ZoomableImageView(image: img)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Sestavuji desku…").foregroundColor(.secondary)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle(scan.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let img = compositeImage {
                        ShareLink(item: Image(uiImage: img),
                                  preview: SharePreview(scan.displayName,
                                                        image: Image(uiImage: img))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                phaseStatus
            }
        }
        .onAppear { buildImage() }
    }

    private var phaseStatus: some View {
        HStack(spacing: 12) {
            ForEach(ScanPhase.allCases, id: \.self) { phase in
                HStack(spacing: 4) {
                    Circle().fill(scan.hasStitch(phase) ? phase.color : Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(phase.shortName).font(.caption2).foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.black.opacity(0.8))
    }

    private func buildImage() {
        Task.detached(priority: .userInitiated) {
            let img = buildUnfoldedImage(scan: scan)
            await MainActor.run { compositeImage = img }
        }
    }
}

// MARK: - Zobrazení jedné fáze (z listu)

struct PhaseImageView: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZoomableImageView(image: image)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.black)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Zavřít") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview(title, image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}
