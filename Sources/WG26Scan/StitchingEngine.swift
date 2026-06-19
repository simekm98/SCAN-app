import Foundation
import UIKit
import CoreGraphics

struct StitchResult {
    let image: UIImage
    let widthMM: Float
    let heightMM: Float
    let pxPerMM: Float
}

final class StitchingEngine {

    var pxPerMM: Float = 10.0
    var progressHandler: ((Double, String) -> Void)?

    func stitch(scanFolder: URL) async throws -> StitchResult {
        let metadata = try loadMetadata(from: scanFolder)
        let frames   = metadata.frames
        guard !frames.isEmpty else { throw StitchError.noFrames }

        report(0.05, "Čtu první snímek…")
        let firstImg = try loadImage(index: 0, folder: scanFolder)
        let imgW: Float = Float(firstImg.size.width)
        let imgH: Float = Float(firstImg.size.height)

        // Průměrná výška nad deskou
        let distances: [Float] = frames.compactMap { $0.averageBoardDistanceM }
        let avgDist: Float = distances.isEmpty ? 0.35 : distances.reduce(0, +) / Float(distances.count)
        let avgDistMM: Float = avgDist * 1000.0

        // Focal length odhad (iPhone wide ≈ 77° HFOV)
        let fx: Float = imgW / (2.0 * tan(38.5 * .pi / 180.0))
        let fy: Float = imgH / (2.0 * tan(38.5 * .pi / 180.0))

        // Fyzické rozměry záběru [mm]
        let framePhysW: Float = imgW * avgDistMM / fx
        let framePhysH: Float = imgH * avgDistMM / fy

        // Kumulativní pozice [mm]
        var cumPos: [Float] = [0.0]
        for i in 1..<frames.count {
            cumPos.append(cumPos[i-1] + frames[i].stepDistance * 1000.0)
        }
        let totalLength: Float = (cumPos.last ?? 0) + framePhysH

        // Výstupní rozměry
        let outW: Int = max(1, Int(framePhysW * pxPerMM))
        let outH: Int = max(1, Int(totalLength  * pxPerMM))
        guard outW > 0 && outH > 0 else { throw StitchError.invalidGeometry }

        report(0.10, "Mozaika \(outW)×\(outH) px")

        // Omezení na 8192 px
        let scaleF: Float = min(1.0, Float(8192) / Float(max(outW, outH)))
        let finalW: Int = max(1, Int(Float(outW) * scaleF))
        let finalH: Int = max(1, Int(Float(outH) * scaleF))
        let effPx:  Float = pxPerMM * scaleF

        var accumR = [Float](repeating: 0, count: finalW * finalH)
        var accumG = [Float](repeating: 0, count: finalW * finalH)
        var accumB = [Float](repeating: 0, count: finalW * finalH)
        var accumW = [Float](repeating: 0, count: finalW * finalH)

        for i in 0..<frames.count {
            let prog = 0.10 + 0.80 * Double(i) / Double(frames.count)
            report(prog, "Snímek \(i+1)/\(frames.count)…")

            let frameD: Float = (frames[i].averageBoardDistanceM ?? avgDist) * 1000.0
            let fW: Float = imgW * frameD / fx
            let fH: Float = imgH * frameD / fy

            let pos: Float = cumPos[i]
            let cx: Float  = Float(finalW) / 2.0
            let cy: Float  = (pos + fH / 2.0) * effPx

            let px0: Int = Int((cx - fW * effPx / 2).rounded())
            let px1: Int = Int((cx + fW * effPx / 2).rounded())
            let py0: Int = Int((cy - fH * effPx / 2).rounded())
            let py1: Int = Int((cy + fH * effPx / 2).rounded())

            let cx0: Int = max(0, px0); let cx1: Int = min(finalW, px1)
            let cy0: Int = max(0, py0); let cy1: Int = min(finalH, py1)
            guard cx0 < cx1 && cy0 < cy1 else { continue }

            guard let img = try? loadImage(index: i, folder: scanFolder) else { continue }
            let tw: Int = cx1 - cx0
            let th: Int = cy1 - cy0
            guard let resized = resizeImage(img, to: CGSize(width: tw, height: th)),
                  let pixels  = pixelData(of: resized) else { continue }

            let sx0: Int = cx0 - px0
            let sy0: Int = cy0 - py0
            let totalW: Int = px1 - px0
            let totalH: Int = py1 - py0

            for row in 0..<th {
                let srcRow: Int = sy0 + row
                let wy: Float = edgeWeight(pos: srcRow, total: totalH)
                for col in 0..<tw {
                    let srcCol: Int = sx0 + col
                    let wx: Float = edgeWeight(pos: srcCol, total: totalW)
                    let w: Float  = wx * wy

                    let srcIdx: Int = (row * tw + col) * 4
                    let dstIdx: Int = (cy0 + row) * finalW + (cx0 + col)

                    accumR[dstIdx] += Float(pixels[srcIdx])     * w
                    accumG[dstIdx] += Float(pixels[srcIdx + 1]) * w
                    accumB[dstIdx] += Float(pixels[srcIdx + 2]) * w
                    accumW[dstIdx] += w
                }
            }
        }

        report(0.92, "Sestavuji výsledek…")
        var output = [UInt8](repeating: 255, count: finalW * finalH * 4)
        for idx in 0..<(finalW * finalH) {
            let w = accumW[idx]
            if w > 0 {
                output[idx * 4]     = UInt8(min(255.0, (accumR[idx] / w).rounded()))
                output[idx * 4 + 1] = UInt8(min(255.0, (accumG[idx] / w).rounded()))
                output[idx * 4 + 2] = UInt8(min(255.0, (accumB[idx] / w).rounded()))
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &output, width: finalW, height: finalH,
                                   bitsPerComponent: 8, bytesPerRow: finalW * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImg = ctx.makeImage() else { throw StitchError.renderFailed }

        let result = UIImage(cgImage: cgImg)
        let outURL = scanFolder.appendingPathComponent("mozaika.png")
        if let data = result.pngData() { try data.write(to: outURL) }

        report(1.0, "Hotovo!")
        return StitchResult(image: result, widthMM: framePhysW, heightMM: totalLength, pxPerMM: effPx)
    }

    // MARK: - Helpers

    private func edgeWeight(pos: Int, total: Int) -> Float {
        guard total > 1 else { return 1.0 }
        let t = Float(pos) / Float(total)
        let edge = min(t, 1.0 - t) * 6.0  // rampup v 1/6 šířky
        return min(1.0, edge)
    }

    private func loadMetadata(from folder: URL) throws -> ScanMetadata {
        let data = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        return try JSONDecoder().decode(ScanMetadata.self, from: data)
    }

    private func loadImage(index: Int, folder: URL) throws -> UIImage {
        let url = folder.appendingPathComponent(String(format: "frame_%04d.heic", index))
        guard let img = UIImage(contentsOfFile: url.path) else { throw StitchError.imageNotFound(index) }
        return img
    }

    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage? {
        guard size.width > 0 && size.height > 0 else { return nil }
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let r = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return r
    }

    private func pixelData(of image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width; let h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
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
