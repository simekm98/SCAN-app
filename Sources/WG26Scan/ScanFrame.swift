import Foundation
import ARKit
import UIKit

/// Jeden prostorově vzorkovaný snímek ze skenu.
/// Obsahuje obraz, hloubkovou mapu a přesnou polohu kamery v momentě záznamu.
struct ScanFrame {
    let index: Int
    let timestamp: TimeInterval

    /// Barevný obraz z kamery (full-resolution YCbCr pixel buffer z ARKit)
    let colorBuffer: CVPixelBuffer

    /// Hloubková mapa z LiDARu (Float32, v metrech) – může být nil u starších zařízení
    let depthBuffer: CVPixelBuffer?

    /// Confidence mapa ke každému pixelu hloubky (0/1/2 = low/medium/high)
    let depthConfidenceBuffer: CVPixelBuffer?

    /// Transformační matice kamery v world space (4×4, metrické jednotky)
    let cameraTransform: simd_float4x4

    /// Intrinsická matice kamery (pro přepočet pixel → 3D bod)
    let cameraIntrinsics: simd_float3x3

    /// Rozlišení obrazového bufferu
    let imageResolution: CGSize

    /// Vzdálenost posunu od předchozího framu v metrech
    let stepDistance: Float

    /// Průměrná vzdálenost desky od telefonu v metrech (z LiDAR),
    /// zprůměrovaná přes centrální oblast hloubkové mapy
    var averageBoardDistance: Float? {
        guard let depthBuffer = depthBuffer else { return nil }
        return ScanFrame.centerAverageDepth(from: depthBuffer)
    }

    private static func centerAverageDepth(from buffer: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let ptr = base.assumingMemoryBound(to: Float32.self)

        // Centrální čtvrtina snímku
        let x0 = w / 4, x1 = 3 * w / 4
        let y0 = h / 4, y1 = 3 * h / 4
        var sum: Float = 0
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let v = ptr[y * w + x]
                if v > 0.01 && v < 5.0 { // ignoruj NaN a hodnoty mimo smysluplný rozsah
                    sum += v
                    count += 1
                }
            }
        }
        return count > 0 ? sum / Float(count) : nil
    }
}

/// Metadata celé série pro export do JSON
struct ScanMetadata: Codable {
    let scanID: String
    let startDate: String
    let stepMM: Float
    let totalFrames: Int
    let frames: [FrameRecord]

    struct FrameRecord: Codable {
        let index: Int
        let timestamp: TimeInterval
        let stepDistance: Float
        let averageBoardDistanceM: Float?
        let cameraTransform: [Float] // 16 prvků row-major
    }
}
