import Foundation
import ARKit
import UIKit
import simd

enum ScanSessionState {
    case idle
    case initializing
    case tracking
    case scanning
    case paused
    case failed(String)
}

final class ARScanSession: NSObject, ObservableObject {

    // MARK: - Publikované stavy

    @Published var state: ScanSessionState = .idle
    @Published var capturedFrameCount: Int = 0
    @Published var trackingQuality: ARCamera.TrackingState = .notAvailable
    @Published var currentBoardDistanceM: Float? = nil
    @Published var lastError: String? = nil

    // MARK: - Konfigurace

    /// Prostorový krok v mm (aktivní při captureMode == .spatial)
    var stepMM: Float = 50.0

    /// Frekvence snímání v Hz (aktivní při captureMode == .temporal)
    var captureHz: Double = 1.0

    /// Mód snímání
    var captureMode: CaptureMode = .spatial

    // MARK: - ARKit

    let arSession = ARSession()
    private var configuration: ARWorldTrackingConfiguration?

    // MARK: - Odometrie a extrakce

    private var lastCaptureTransform: simd_float4x4? = nil
    private var frameIndex: Int = 0
    private var isScanning = false
    private var lastCaptureTime: TimeInterval = 0

    // MARK: - Výstup

    private var outputFolderURL: URL?
    private var frameRecords: [ScanMetadata.FrameRecord] = []
    private let ioQueue = DispatchQueue(label: "wg26.arscan.io", qos: .utility)

    var onFrameCaptured: ((ScanFrame) -> Void)?
    var onScanFinished: ((URL) -> Void)?

    override init() {
        super.init()
        arSession.delegate = self
    }

    // MARK: - Životní cyklus

    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            setState(.failed("ARWorldTracking není podporováno."))
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
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

    func stopSession() {
        stopScan()
        arSession.pause()
        setState(.idle)
    }

    // MARK: - Ovládání skenu

    func startScan() {
        guard case .tracking = state else {
            setError("Tracking není stabilizovaný.")
            return
        }
        let folder = createOutputFolder()
        outputFolderURL = folder
        frameIndex = 0
        frameRecords = []
        lastCaptureTransform = nil
        lastCaptureTime = 0
        DispatchQueue.main.async { self.capturedFrameCount = 0 }
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

    // MARK: - Zpracování frame

    private func processFrame(_ frame: ARFrame) {
        let dist = extractCenterDepth(frame: frame)
        DispatchQueue.main.async {
            self.trackingQuality = frame.camera.trackingState
            self.currentBoardDistanceM = dist
        }
        if case .initializing = state {
            if case .normal = frame.camera.trackingState {
                setState(.tracking)
            }
        }
        guard isScanning else { return }

        let currentTransform = frame.camera.transform
        let currentTime = frame.timestamp

        switch captureMode {
        case .spatial:
            if lastCaptureTransform == nil {
                captureFrame(frame, stepDistance: 0)
                lastCaptureTransform = currentTransform
                return
            }
            let step = translationDistance(from: lastCaptureTransform!, to: currentTransform)
            if step >= stepMM / 1000.0 {
                captureFrame(frame, stepDistance: step)
                lastCaptureTransform = currentTransform
            }

        case .temporal:
            let interval = 1.0 / captureHz
            if lastCaptureTime == 0 || (currentTime - lastCaptureTime) >= interval {
                let step = lastCaptureTransform.map {
                    translationDistance(from: $0, to: currentTransform)
                } ?? 0
                captureFrame(frame, stepDistance: step)
                lastCaptureTransform = currentTransform
                lastCaptureTime = currentTime
            }
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

    // MARK: - Ukládání

    private func saveFrameToDisk(_ scanFrame: ScanFrame, folder: URL) {
        let idx = scanFrame.index
        if let img = imageFromPixelBuffer(scanFrame.colorBuffer) {
            let url = folder.appendingPathComponent(String(format: "frame_%04d.heic", idx))
            if let data = img.heicData(compressionQuality: 0.92) {
                try? data.write(to: url)
            }
        }
        if let db = scanFrame.depthBuffer, let data = rawDepthData(from: db) {
            let url = folder.appendingPathComponent(String(format: "depth_%04d.bin", idx))
            try? data.write(to: url)
        }
    }

    private func imageFromPixelBuffer(_ buffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func rawDepthData(from buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = UInt32(CVPixelBufferGetWidth(buffer))
        let h = UInt32(CVPixelBufferGetHeight(buffer))
        var data = Data()
        withUnsafeBytes(of: w.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: h.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(bytes: base, count: CVPixelBufferGetDataSize(buffer)))
        return data
    }

    private func writeMetadata(records: [ScanMetadata.FrameRecord], to folder: URL) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let meta = ScanMetadata(
            scanID: folder.lastPathComponent,
            startDate: fmt.string(from: Date()),
            stepMM: stepMM,
            totalFrames: records.count,
            frames: records
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: folder.appendingPathComponent("metadata.json"))
        }
    }

    // MARK: - Helpers

    private func translationDistance(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let d = b.columns.3 - a.columns.3
        return sqrt(d.x*d.x + d.y*d.y + d.z*d.z)
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
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let v = base.assumingMemoryBound(to: Float32.self)[h/2 * w + w/2]
        return (v > 0.01 && v < 5.0) ? v : nil
    }

    private func createOutputFolder() -> URL {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("scan_\(fmt.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func setState(_ s: ScanSessionState) { DispatchQueue.main.async { self.state = s } }
    private func setError(_ m: String) { DispatchQueue.main.async { self.lastError = m } }
}

// MARK: - ARSessionDelegate

extension ARScanSession: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) { processFrame(frame) }
    func session(_ session: ARSession, didFailWithError error: Error) { setState(.failed(error.localizedDescription)) }
    func sessionWasInterrupted(_ session: ARSession) { isScanning = false; setState(.paused) }
    func sessionInterruptionEnded(_ session: ARSession) { setState(.tracking) }
}

// MARK: - UIImage HEIC

private extension UIImage {
    func heicData(compressionQuality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil),
              let cg = self.cgImage else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
