import Foundation
import UIKit
import CoreImage
import Vision

struct StitchResult {
    let image: UIImage
    let widthMM: Float
    let heightMM: Float
    let pxPerMM: Float
}

/// Vision-based panoramic stitching – zarovnává snímky podle obsahu obrazu (jako iOS Panorama),
/// bez závislosti na LiDAR vzdálenosti nebo ARKit odometrii.
final class StitchingEngine {

    var pxPerMM: Float = 10.0
    var progressHandler: ((Double, String) -> Void)?

    func stitch(scanFolder: URL) async throws -> StitchResult {
        let metadata = try loadMetadata(from: scanFolder)
        let frames   = metadata.frames
        guard !frames.isEmpty else { throw StitchError.noFrames }

        report(0.05, "Načítám snímky…")

        // Načti snímky jako UIImage (správná orientace HEIC)
        var images: [UIImage] = []
        for i in 0..<frames.count {
            let url = scanFolder.appendingPathComponent(String(format: "frame_%04d.heic", i))
            if let img = UIImage(contentsOfFile: url.path) { images.append(img) }
        }
        guard !images.isEmpty else { throw StitchError.noFrames }

        let imgW = images[0].size.width
        let imgH = images[0].size.height

        report(0.10, "Zarovnávám \(images.count) snímků…")

        // Pairwise Vision registrace → kumulativní y-pozice každého snímku
        var yOffsets: [CGFloat] = [0.0]
        var cumY: CGFloat = 0.0

        let avgDist: Float = {
            let d = frames.compactMap { $0.averageBoardDistanceM }
            return d.isEmpty ? 0.35 : d.reduce(0, +) / Float(d.count)
        }()
        // Snímky jsou v portrait orientaci (imgH = dlouhá osa = podél desky).
        // Horizontální FOV (původně landscape šířka → nyní imgH): ~77° celkem, fx pro imgH.
        let fx = Float(imgH) / (2.0 * tan(38.5 * .pi / 180.0))
        let framePhysHmm = Float(imgH) * avgDist * 1000.0 / fx

        for i in 1..<images.count {
            let prog = 0.10 + 0.55 * Double(i) / Double(images.count)
            report(prog, "Zarovnávám \(i)/\(images.count)…")

            // Vision alignment (25 % velikost pro rychlost)
            let advance: CGFloat
            if let dy = visionAdvance(from: images[i-1], to: images[i]),
               dy > 2.0 {
                advance = dy
            } else {
                // Fallback: ARKit krok nebo FOV odhad
                let stepMM = frames[i].stepDistance > 0
                    ? Float(frames[i].stepDistance) * 1000.0
                    : framePhysHmm * 0.5          // výchozí 50 % překryv
                advance = CGFloat(stepMM * pxPerMM)
            }
            cumY += advance
            yOffsets.append(cumY)
        }

        let canvasH = Int(ceil(yOffsets.last! + imgH))
        let canvasW = Int(ceil(imgW))
        let scale   = min(1.0, 8192.0 / CGFloat(max(canvasW, canvasH)))
        let finalW  = max(1, Int(CGFloat(canvasW) * scale))
        let finalH  = max(1, Int(CGFloat(canvasH) * scale))

        report(0.67, "Skládám mozaiku \(finalW)×\(finalH) px…")

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0; fmt.opaque = true

        let result = UIGraphicsImageRenderer(
            size: CGSize(width: finalW, height: finalH), format: fmt
        ).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: finalW, height: finalH))

            for (i, img) in images.enumerated() {
                let rect = CGRect(
                    x: 0,
                    y: yOffsets[i] * scale,
                    width: CGFloat(finalW),
                    height: imgH * scale
                )
                img.draw(in: rect)
                let prog = 0.67 + 0.30 * Double(i) / Double(images.count)
                DispatchQueue.main.async { self.progressHandler?(prog, "Renderuji \(i+1)/\(images.count)…") }
            }
        }

        let outURL = scanFolder.appendingPathComponent("mozaika.png")
        if let data = result.pngData() { try data.write(to: outURL) }

        let effPx = Float(scale) * pxPerMM
        report(1.0, "Hotovo!")
        return StitchResult(
            image: result,
            widthMM: Float(imgW) / max(effPx, 0.01),
            heightMM: Float(canvasH) / max(effPx, 0.01),
            pxPerMM: effPx
        )
    }

    // MARK: - Vision pairwise alignment

    /// Vrátí posun (v px plného rozlišení, UIKit y-dolů) mezi snímky prev → curr.
    private func visionAdvance(from prev: UIImage, to curr: UIImage) -> CGFloat? {
        let vScale: CGFloat = 0.25
        guard let prevCI = downsampled(prev, scale: vScale),
              let currCI = downsampled(curr, scale: vScale) else { return nil }

        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: prevCI)
        let handler = VNImageRequestHandler(ciImage: currCI, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation
        else { return nil }

        // CIImage: y nahoru → záporné ty = kamera se posunula "dolů" (kupředu po desce)
        // UIKit: y dolů → kladný posun
        let dy = obs.alignmentTransform.ty / vScale
        return dy > 0 ? dy : nil
    }

    private func downsampled(_ img: UIImage, scale: CGFloat) -> CIImage? {
        let sz = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        guard sz.width > 0 && sz.height > 0 else { return nil }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0; fmt.opaque = true
        let small = UIGraphicsImageRenderer(size: sz, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: sz))
        }
        return CIImage(image: small)
    }

    // MARK: - Helpers

    private func loadMetadata(from folder: URL) throws -> ScanMetadata {
        let data = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        return try JSONDecoder().decode(ScanMetadata.self, from: data)
    }

    private func report(_ p: Double, _ msg: String) {
        DispatchQueue.main.async { self.progressHandler?(p, msg) }
    }
}

enum StitchError: LocalizedError {
    case noFrames, invalidGeometry, imageNotFound(Int), renderFailed
    var errorDescription: String? {
        switch self {
        case .noFrames:             return "Žádné snímky k stitchingu."
        case .invalidGeometry:      return "Neplatná geometrie."
        case .imageNotFound(let i): return "frame_\(i) nenalezen."
        case .renderFailed:         return "Render selhal."
        }
    }
}
