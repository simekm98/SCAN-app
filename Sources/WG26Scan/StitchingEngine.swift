import Foundation
import UIKit
import CoreGraphics
import Accelerate

/// Výsledek stitchingu
struct StitchResult {
    let image: UIImage
    let widthMM: Float
    let heightMM: Float
    let pxPerMM: Float
}

/// Geometricky korektní stitching lineárního skenu desky.
///
/// Předpoklady:
///   - Telefon ve vodorovné poloze (landscape), kamera dolů
///   - Pohyb podél délky desky (osa kolejnice)
///   - ARKit odometrie v metadata.json
final class StitchingEngine {

    var pxPerMM: Float = 10.0      // nastavitelné uživatelem
    var progressHandler: ((Double, String) -> Void)?

    // MARK: - Vstupní bod

    func stitch(scanFolder: URL) async throws -> StitchResult {
        let metadata = try loadMetadata(from: scanFolder)
        let frames   = metadata.frames
        guard !frames.isEmpty else { throw StitchError.noFrames }

        report(0.05, "Čtu první snímek…")
        let firstImg = try loadImage(index: 0, folder: scanFolder)
        let imgW = firstImg.size.width
        let imgH = firstImg.size.height

        // --- Geometrie ---
        // Průměrná výška kamery nad deskou
        let distances = frames.compactMap { $0.averageBoardDistanceM }.map { Float($0) }
        let avgDist: Float = distances.isEmpty ? 0.35 : distances.reduce(0, +) / Float(distances.count)
        let avgDistMM = avgDist * 1000.0

        // Přibližná focal length (ARKit wide, ~≈ min(w,h)*1.3 pro 4K)
        let fx = Float(imgW) * 1.3
        let fy = Float(imgH) * 1.3

        // Fyzické rozměry jednoho snímku na povrchu desky [mm]
        let framePhysW = Float(imgW) * avgDistMM / fx   // šířka desky
        let framePhysH = Float(imgH) * avgDistMM / fy   // podél pohybu

        // Kumulativní pozice každého snímku podél kolejnice [mm]
        var cumPos: [Float] = [0.0]
        for i in 1..<frames.count {
            cumPos.append(cumPos[i-1] + frames[i].stepDistance * 1000.0)
        }
        let totalLength = (cumPos.last ?? 0) + framePhysH

        // Rozměry výstupní mozaiky [px]
        let outW = Int(framePhysW * pxPerMM)
        let outH = Int(totalLength * pxPerMM)

        guard outW > 0 && outH > 0 else { throw StitchError.invalidGeometry }
        report(0.10, "Mozaika \(outW)×\(outH) px (\(Int(framePhysW))×\(Int(totalLength)) mm)")

        // Limit: max 8192 px v každé ose (iOS texture limit)
        let scaleLimit = min(1.0, Float(min(8192, 8192)) / Float(max(outW, outH)))
        let finalW = Int(Float(outW) * scaleLimit)
        let finalH = Int(Float(outH) * scaleLimit)
        let effectivePxPerMM = pxPerMM * scaleLimit

        // --- Výstupní buffer ---
        let bytesPerPixel = 4
        var accumR = [Float](repeating: 0, count: finalW * finalH)
        var accumG = [Float](repeating: 0, count: finalW * finalH)
        var accumB = [Float](repeating: 0, count: finalW * finalH)
        var accumW = [Float](repeating: 0, count: finalW * finalH)

        // --- Skládáme snímky ---
        for (i, frame) in frames.enumerated() {
            let progress = 0.10 + 0.80 * Double(i) / Double(frames.count)
            report(progress, "Snímek \(i+1)/\(frames.count)…")

            let d = Float(frame.averageBoardDistanceM ?? Double(avgDist)) * 1000.0
            let fW = Float(imgW) * d / fx
            let fH = Float(imgH) * d / fy

            let pos = cumPos[i]

            // Pozice v mozaice [px]
            let cx = Float(finalW) / 2.0
            let cy = (pos + fH / 2.0) * effectivePxPerMM

            let px0 = Int((cx - fW * effectivePxPerMM / 2).rounded())
            let px1 = Int((cx + fW * effectivePxPerMM / 2).rounded())
            let py0 = Int((cy - fH * effectivePxPerMM / 2).rounded())
            let py1 = Int((cy + fH * effectivePxPerMM / 2).rounded())

            // Ořez
            let cx0 = max(0, px0); let cx1 = min(finalW, px1)
            let cy0 = max(0, py0); let cy1 = min(finalH, py1)
            guard cx0 < cx1 && cy0 < cy1 else { continue }

            guard let img = try? loadImage(index: i, folder: scanFolder) else { continue }
            let tW = cx1 - cx0; let tH = cy1 - cy0

            guard let resized = resizeImage(img, to: CGSize(width: tW, height: tH)),
                  let pixels  = pixelData(of: resized) else { continue }

            let sx0 = cx0 - px0; let sy0 = cy0 - py0

            for row in 0..<tH {
                let srcRow = sy0 + row
                // Feather weight: 1 у краёв падает до 0
                let wy = edgeWeight(row: srcRow, total: py1 - py0)
                for col in 0..<tW {
                    let srcCol = sx0 + col
                    let wx  = edgeWeight(row: srcCol, total: px1 - px0)
                    let w   = wx * wy

                    let srcIdx = (row * tW + col) * 4
                    let dstIdx = (cy0 + row) * finalW + (cx0 + col)

                    accumR[dstIdx] += Float(pixels[srcIdx])     * w
                    accumG[dstIdx] += Float(pixels[srcIdx + 1]) * w
                    accumB[dstIdx] += Float(pixels[srcIdx + 2]) * w
                    accumW[dstIdx] += w
                }
            }
        }

        // --- Normalizace a výstup ---
        report(0.92, "Sestavuji výsledek…")
        var output = [UInt8](repeating: 255, count: finalW * finalH * bytesPerPixel)
        for idx in 0..<(finalW * finalH) {
            let w = accumW[idx]
            if w > 0 {
                output[idx * 4]     = UInt8(min(255, (accumR[idx] / w).rounded()))
                output[idx * 4 + 1] = UInt8(min(255, (accumG[idx] / w).rounded()))
                output[idx * 4 + 2] = UInt8(min(255, (accumB[idx] / w).rounded()))
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &output,
                                  width: finalW, height: finalH,
                                  bitsPerComponent: 8, bytesPerRow: finalW * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImg = ctx.makeImage() else { throw StitchError.renderFailed }

        let result = UIImage(cgImage: cgImg)

        // Uložit do složky skenu
        let outURL = scanFolder.appendingPathComponent("mozaika.png")
        if let data = result.pngData() {
            try data.write(to: outURL)
        }

        report(1.0, "Hotovo!")
        return StitchResult(
            image: result,
            widthMM: framePhysW,
            heightMM: totalLength,
            pxPerMM: effectivePxPerMM
        )
    }

    // MARK: - Helpers

    private func edgeWeight(row: Int, total: Int) -> Float {
        guard total > 0 else { return 1 }
        let t = Float(row) / Float(total)
        let mirror = 1.0 - t
        let edge = min(t, mirror) * 2.0  // 0..1
        return min(1.0, edge * 3.0)       // rampup v 1/3 šířky
    }

    private func loadMetadata(from folder: URL) throws -> ScanMetadata {
        let url = folder.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ScanMetadata.self, from: data)
    }

    private func loadImage(index: Int, folder: URL) throws -> UIImage {
        let name = String(format: "frame_%04d.heic", index)
        let url  = folder.appendingPathComponent(name)
        guard let img = UIImage(contentsOfFile: url.path) else {
            throw StitchError.imageNotFound(index)
        }
        return img
    }

    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage? {
        guard size.width > 0 && size.height > 0 else { return nil }
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    private func pixelData(of image: UIImage) -> [UInt8]? {
        guard let cgImg = image.cgImage else { return nil }
        let w = cgImg.width; let h = cgImg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    private func report(_ progress: Double, _ message: String) {
        DispatchQueue.main.async {
            self.progressHandler?(progress, message)
        }
    }
}

enum StitchError: LocalizedError {
    case noFrames
    case invalidGeometry
    case imageNotFound(Int)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noFrames:          return "Žádné snímky k stitchingu."
        case .invalidGeometry:   return "Neplatná geometrie skenu."
        case .imageNotFound(let i): return "Snímek frame_\(i) nenalezen."
        case .renderFailed:      return "Vykreslení mozaiky selhalo."
        }
    }
}
