import Foundation
import ARKit
import UIKit
import simd

enum ScanSessionState {
    case idle, initializing, tracking, scanning, paused
    case failed(String)
}

final class ARScanSession: NSObject, ObservableObject {

    @Published var state: ScanSessionState = .idle
    @Published var capturedFrameCount: Int = 0
    @Published var trackingQuality: ARCamera.TrackingState = .notAvailable
    @Published var currentBoardDistanceM: Float? = nil
    @Published var lastError: String? = nil
    @Published var totalDistanceMM: Float = 0

    var stepMM: Float = 50.0
    var captureHz: Double = 1.0
    var captureMode: CaptureMode = .spatial
    var stopCondition: StopCondition = .manual

    // Jméno desky a plocha pro pojmenování složky
    var boardName: String = "Deska"
    // surface removed – folder controlled via overrideOutputFolder

    let arSession = ARSession()

    private var lastCaptureTransform: simd_float4x4? = nil
    private var frameIndex: Int = 0
    private var isScanning = false
    private var lastCaptureTime: TimeInterval = 0
    private var accumulatedDistanceMM: Float = 0

    var overrideOutputFolder: URL? = nil
    private(set) var outputFolderURL: URL?
    private var frameRecords: [ScanMetadata.FrameRecord] = []
    private let ioQueue = DispatchQueue(label: "wg26.arscan.io", qos: .utility)

    var onFrameCaptured: ((ScanFrame) -> Void)?
    var onScanFinished: ((URL) -> Void)?

    override init() { super.init(); arSession.delegate = self }

    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            setState(.failed("ARWorldTracking není podporováno.")); return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
        if let best = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.imageResolution.width >= 1920 })
            .sorted(by: { $0.imageResolution.width > $1.imageResolution.width }).first {
            config.videoFormat = best
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        setState(.initializing)
    }

    func stopSession() { stopScan(); arSession.pause(); setState(.idle) }

    func startScan() {
        guard case .tracking = state else { setError("Tracking není stabilizovaný."); return }
        let folder = overrideOutputFolder ?? createOutputFolder()
        outputFolderURL = folder
        frameIndex = 0; frameRecords = []; lastCaptureTransform = nil
        lastCaptureTime = 0; accumulatedDistanceMM = 0
        DispatchQueue.main.async { self.capturedFrameCount = 0; self.totalDistanceMM = 0 }
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
            DispatchQueue.main.async { self.setState(.tracking); self.onScanFinished?(folder) }
        }
    }

    private func processFrame(_ frame: ARFrame) {
        let dist = extractCenterDepth(frame: frame)
        DispatchQueue.main.async { self.trackingQuality = frame.camera.trackingState; self.currentBoardDistanceM = dist }
        if case .initializing = state { if case .normal = frame.camera.trackingState { setState(.tracking) } }
        guard isScanning else { return }

        let currentTransform = frame.camera.transform
        let currentTime = frame.timestamp

        switch captureMode {
        case .spatial:
            if lastCaptureTransform == nil {
                captureFrame(frame, stepDistance: 0); lastCaptureTransform = currentTransform; return
            }
            let step = translationDistance(from: lastCaptureTransform!, to: currentTransform)
            if step * 1000 >= stepMM {
                captureFrame(frame, stepDistance: step)
                lastCaptureTransform = currentTransform
                accumulatedDistanceMM += step * 1000
                checkStop()
            }
        case .temporal:
            let interval = 1.0 / captureHz
            if lastCaptureTime == 0 || (currentTime - lastCaptureTime) >= interval {
                let step = lastCaptureTransform.map { translationDistance(from: $0, to: currentTransform) } ?? 0
                captureFrame(frame, stepDistance: step)
                lastCaptureTransform = currentTransform; lastCaptureTime = currentTime
                accumulatedDistanceMM += step * 1000; checkStop()
            }
        }
    }

    private func checkStop() {
        switch stopCondition {
        case .manual: break
        case .distance(let mm): if accumulatedDistanceMM >= mm { stopScan() }
        case .frameCount(let n): if frameIndex >= n { stopScan() }
        }
        DispatchQueue.main.async { self.totalDistanceMM = self.accumulatedDistanceMM }
    }

    private func captureFrame(_ frame: ARFrame, stepDistance: Float) {
        let idx = frameIndex; frameIndex += 1
        let sf = ScanFrame(index: idx, timestamp: frame.timestamp,
                           colorBuffer: frame.capturedImage,
                           depthBuffer: frame.sceneDepth?.depthMap,
                           depthConfidenceBuffer: frame.sceneDepth?.confidenceMap,
                           cameraTransform: frame.camera.transform,
                           cameraIntrinsics: frame.camera.intrinsics,
                           imageResolution: frame.camera.imageResolution,
                           stepDistance: stepDistance)
        frameRecords.append(ScanMetadata.FrameRecord(index: idx, timestamp: frame.timestamp,
                            stepDistance: stepDistance, averageBoardDistanceM: sf.averageBoardDistance,
                            cameraTransform: transformToArray(frame.camera.transform)))
        let folder = outputFolderURL
        ioQueue.async { [weak self] in
            guard let self = self, let folder = folder else { return }
            self.saveFrameToDisk(sf, folder: folder)
        }
        DispatchQueue.main.async { self.capturedFrameCount = idx + 1; self.onFrameCaptured?(sf) }
    }

    private func saveFrameToDisk(_ sf: ScanFrame, folder: URL) {
        if let img = imageFromPixelBuffer(sf.colorBuffer), let data = img.heicData(compressionQuality: 0.92) {
            try? data.write(to: folder.appendingPathComponent(String(format: "frame_%04d.heic", sf.index)))
        }
        if let db = sf.depthBuffer, let data = rawDepthData(from: db) {
            try? data.write(to: folder.appendingPathComponent(String(format: "depth_%04d.bin", sf.index)))
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
        var data = Data()
        var w = UInt32(CVPixelBufferGetWidth(buffer)); var h = UInt32(CVPixelBufferGetHeight(buffer))
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        data.append(Data(bytes: base, count: CVPixelBufferGetDataSize(buffer)))
        return data
    }

    private func writeMetadata(records: [ScanMetadata.FrameRecord], to folder: URL) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let meta = ScanMetadata(scanID: folder.lastPathComponent, startDate: fmt.string(from: Date()),
                                stepMM: stepMM, totalFrames: records.count, frames: records)
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: folder.appendingPathComponent("metadata.json")) }
    }

    private func translationDistance(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let d = b.columns.3 - a.columns.3; return sqrt(d.x*d.x + d.y*d.y + d.z*d.z)
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
        let safe = boardName.replacingOccurrences(of: " ", with: "")
        let name = "scan_\(safe)_\(fmt.string(from: Date()))"
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func setState(_ s: ScanSessionState) { DispatchQueue.main.async { self.state = s } }
    private func setError(_ m: String) { DispatchQueue.main.async { self.lastError = m } }
}

extension ARScanSession: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) { processFrame(frame) }
    func session(_ session: ARSession, didFailWithError error: Error) { setState(.failed(error.localizedDescription)) }
    func sessionWasInterrupted(_ session: ARSession) { isScanning = false; setState(.paused) }
    func sessionInterruptionEnded(_ session: ARSession) { setState(.tracking) }
}

private extension UIImage {
    func heicData(compressionQuality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil),
              let cg = self.cgImage else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
