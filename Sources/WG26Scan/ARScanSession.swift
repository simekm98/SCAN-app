import Foundation
import ARKit
import UIKit
import simd

/// Stavy ARScanSession pro UI
enum ScanSessionState {
    case idle
    case initializing   // ARKit hledá tracking
    case tracking       // normální tracking, čeká na spuštění skenu
    case scanning       // aktivně sbírá framy
    case paused
    case failed(String)
}

/// Hlavní session pro optický sken řeziva.
/// Kombinuje ARKit world tracking (odometrie + LiDAR depth) s extrakcí
/// prostorově rovnoměrně rozmístěných snímků (každých stepMM milimetrů).
final class ARScanSession: NSObject, ObservableObject {

    // MARK: - Publikované stavy

    @Published var state: ScanSessionState = .idle
    @Published var capturedFrameCount: Int = 0
    @Published var trackingQuality: ARCamera.TrackingState = .notAvailable
    @Published var currentBoardDistanceM: Float? = nil
    @Published var lastError: String? = nil

    // MARK: - Konfigurace (nastavitelné před spuštěním)

    /// Prostorový krok extrakce v milimetrech (výchozí 50 mm)
    var stepMM: Float = 50.0

    /// ISO (pro informaci v metadatech, ARKit ho nastavuje automaticky pokud nezasahujeme)
    var lockedISO: Float? = nil
    var lockedExposureDurationSeconds: Double? = nil
    var lockedLensPosition: Float? = nil

    // MARK: - ARKit

    let arSession = ARSession()
    private var configuration: ARWorldTrackingConfiguration?

    // MARK: - Odometrie a extrakce

    private var lastCaptureTransform: simd_float4x4? = nil
    private var scanOriginTransform: simd_float4x4? = nil
    private var frameIndex: Int = 0
    private var isScanning = false

    // MARK: - Výstup

    private var outputFolderURL: URL?
    private var frameRecords: [ScanMetadata.FrameRecord] = []
    private let ioQueue = DispatchQueue(label: "wg26.arscan.io", qos: .utility)

    /// Volá se po každém zachyceném framu (na main thread)
    var onFrameCaptured: ((ScanFrame) -> Void)?

    /// Volá se po dokončení skenu s cestou ke složce
    var onScanFinished: ((URL) -> Void)?

    // MARK: - Životní cyklus

    override init() {
        super.init()
        arSession.delegate = self
    }

    /// Spustí ARKit session – volej při zobrazení View
    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            setState(.failed("ARWorldTracking není na tomto zařízení podporováno."))
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity

        // LiDAR depth – dostupný jen na Pro/Pro Max modelech
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        } else {
            setError("LiDAR není dostupný – depth mapa nebude k dispozici.")
        }

        // Nejvyšší dostupné rozlišení videa
        if let bestFormat = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.imageResolution.width >= 1920 })
            .sorted(by: { $0.imageResolution.width > $1.imageResolution.width })
            .first {
            config.videoFormat = bestFormat
        }

        self.configuration = config
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        setState(.initializing)
    }

    func pauseSession() {
        arSession.pause()
        if isScanning { isScanning = false }
        setState(.paused)
    }

    func stopSession() {
        stopScan()
        arSession.pause()
        setState(.idle)
    }

    // MARK: - Ovládání skenu

    func startScan() {
        guard case .tracking = state else {
            setError("Tracking není stabilizovaný, nelze spustit sken.")
            return
        }
        let folder = createOutputFolder()
        outputFolderURL = folder
        frameIndex = 0
        frameRecords = []
        lastCaptureTransform = nil
        scanOriginTransform = nil

        DispatchQueue.main.async {
            self.capturedFrameCount = 0
        }

        isScanning = true
        setState(.scanning)
    }

    func stopScan() {
        guard isScanning else { return }
        isScanning = false
        let folder = outputFolderURL
        let records = frameRecords

        ioQueue.async { [weak self] in
            guard let self = self, let folder = folder else { return }
            self.writeMetadata(records: records, to: folder)
            DispatchQueue.main.async {
                self.setState(.tracking)
                self.onScanFinished?(folder)
            }
        }
    }

    // MARK: - Interní extrakce

    private func processFrame(_ frame: ARFrame) {
        // Aktualizace tracking quality a board distance na main thread
        let dist = extractCenterDepth(frame: frame)
        DispatchQueue.main.async {
            self.trackingQuality = frame.camera.trackingState
            self.currentBoardDistanceM = dist
        }

        // Změna stavu initializing → tracking
        if case .initializing = state {
            if case .normal = frame.camera.trackingState {
                setState(.tracking)
            }
        }

        guard isScanning else { return }

        let currentTransform = frame.camera.transform

        // První frame – vždy zachytit a nastavit origin
        if lastCaptureTransform == nil {
            scanOriginTransform = currentTransform
            captureFrame(frame, stepDistance: 0)
            lastCaptureTransform = currentTransform
            return
        }

        // Výpočet posunu od posledního zachyceného framu (v metrech)
        let step = translationDistance(from: lastCaptureTransform!, to: currentTransform)
        let stepM = stepMM / 1000.0

        if step >= stepM {
            captureFrame(frame, stepDistance: step)
            lastCaptureTransform = currentTransform
        }
    }

    private func captureFrame(_ frame: ARFrame, stepDistance: Float) {
        let idx = frameIndex
        frameIndex += 1

        let scanFrame = ScanFrame(
            index: idx,
            timestamp: frame.timestamp,
            colorBuffer: frame.capturedImage,
            depthBuffer: frame.sceneDepth?.depthMap,
            depthConfidenceBuffer: frame.sceneDepth?.confidenceMap,
            cameraTransform: frame.camera.transform,
            cameraIntrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            stepDistance: stepDistance
        )

        let record = ScanMetadata.FrameRecord(
            index: idx,
            timestamp: frame.timestamp,
            stepDistance: stepDistance,
            averageBoardDistanceM: scanFrame.averageBoardDistance,
            cameraTransform: transformToArray(frame.camera.transform)
        )
        frameRecords.append(record)

        let folder = outputFolderURL
        ioQueue.async { [weak self] in
            guard let self = self, let folder = folder else { return }
            self.saveFrameToDisk(scanFrame, folder: folder)
        }

        DispatchQueue.main.async {
            self.capturedFrameCount = idx + 1
            self.onFrameCaptured?(scanFrame)
        }
    }

    // MARK: - Ukládání na disk

    private func saveFrameToDisk(_ scanFrame: ScanFrame, folder: URL) {
        let idx = scanFrame.index

        // Barevný obraz: CVPixelBuffer (YCbCr) → UIImage → HEIC
        if let colorImage = imageFromPixelBuffer(scanFrame.colorBuffer) {
            let colorURL = folder.appendingPathComponent(String(format: "frame_%04d.heic", idx))
            if let heicData = colorImage.heicData(compressionQuality: 0.92) {
                try? heicData.write(to: colorURL)
            }
        }

        // Depth mapa: CVPixelBuffer Float32 → binární .depth soubor (raw float32 array)
        // Formát: 4 bajty šířka (UInt32 LE) + 4 bajty výška + N*4 bajty Float32 row-major
        if let depthBuffer = scanFrame.depthBuffer {
            let depthURL = folder.appendingPathComponent(String(format: "depth_%04d.bin", idx))
            if let data = rawDepthData(from: depthBuffer) {
                try? data.write(to: depthURL)
            }
        }
    }

    private func imageFromPixelBuffer(_ buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func rawDepthData(from buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let w = UInt32(CVPixelBufferGetWidth(buffer))
        let h = UInt32(CVPixelBufferGetHeight(buffer))
        let byteCount = CVPixelBufferGetDataSize(buffer)

        var data = Data()
        withUnsafeBytes(of: w.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: h.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(bytes: base, count: byteCount))
        return data
    }

    private func writeMetadata(records: [ScanMetadata.FrameRecord], to folder: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let meta = ScanMetadata(
            scanID: folder.lastPathComponent,
            startDate: formatter.string(from: Date()),
            stepMM: stepMM,
            totalFrames: records.count,
            frames: records
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: folder.appendingPathComponent("metadata.json"))
        }
    }

    // MARK: - Pomocné funkce

    private func translationDistance(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let delta = b.columns.3 - a.columns.3
        return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    }

    private func transformToArray(_ t: simd_float4x4) -> [Float] {
        [t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
         t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
         t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
         t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w]
    }

    private func extractCenterDepth(frame: ARFrame) -> Float? {
        guard let depth = frame.sceneDepth?.depthMap else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        let w = CVPixelBufferGetWidth(depth)
        let h = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let cx = w / 2, cy = h / 2
        let v = ptr[cy * w + cx]
        return (v > 0.01 && v < 5.0) ? v : nil
    }

    private func createOutputFolder() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "scan_\(formatter.string(from: Date()))"
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func setState(_ newState: ScanSessionState) {
        DispatchQueue.main.async { self.state = newState }
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async { self.lastError = message }
    }
}

// MARK: - ARSessionDelegate

extension ARScanSession: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        processFrame(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        setState(.failed("ARSession chyba: \(error.localizedDescription)"))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        if isScanning { isScanning = false }
        setState(.paused)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        setState(.tracking)
    }
}

// MARK: - UIImage HEIC helper

private extension UIImage {
    func heicData(compressionQuality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil),
              let cgImage = self.cgImage else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
