import Foundation
import AVFoundation
import UIKit

/// Metadata jednoho snímku v sérii - využije se později pro spárování
/// s LiDAR vzdáleností a pro stitching.
struct FrameMetadata: Codable {
    let index: Int
    let timestamp: TimeInterval
    let iso: Float
    let exposureDurationSeconds: Double
    let lensPosition: Float
}

/// Spravuje AVCaptureSession, manuální zámek ISO/expozice/ohniska/bílé barvy
/// a sériové snímání v nastavené frekvenci.
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Stavy pro UI (SwiftUI binding)

    @Published var isSessionRunning = false
    @Published var isLocked = false
    @Published var capturedCount: Int = 0
    @Published var targetCount: Int = 50
    @Published var captureIntervalSeconds: Double = 0.5
    @Published var isCapturing = false
    @Published var lastError: String?
    @Published var droppedFrames: Int = 0

    // MARK: - AVFoundation

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "wg26.camera.session")
    private var device: AVCaptureDevice?
    private let photoOutput = AVCapturePhotoOutput()

    // MARK: - Sériové snímání

    private var captureTimer: DispatchSourceTimer?
    private var captureFolderURL: URL?
    private var internalCapturedCount = 0
    private var internalTargetCount = 0
    private var isPhotoInFlight = false
    private var metadataLog: [FrameMetadata] = []

    // Hodnoty skutečně zamčené na zařízení (po doběhnutí lockAll)
    private var lockedISO: Float = 0
    private var lockedExposureDurationSeconds: Double = 0
    private var lockedLensPosition: Float = 0

    /// Zavolá se po dokončení celé série a předá složku se snímky + metadata.json
    var onSeriesFinished: ((URL) -> Void)?

    override init() {
        super.init()
    }

    // MARK: - Konfigurace session

    func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                self.report(error: "Nenalezena zadní kamera.")
                self.session.commitConfiguration()
                return
            }
            self.device = device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
            } catch {
                self.report(error: "Nelze vytvořit vstup kamery: \(error.localizedDescription)")
                self.session.commitConfiguration()
                return
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.photoOutput.isHighResolutionCaptureEnabled = true
                if #available(iOS 13.0, *) {
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                }
                self.session.addOutput(self.photoOutput)
            }

            // Vypnutí automatických vylepšení, která by rozbila konzistenci mezi snímky
            do {
                try device.lockForConfiguration()
                if device.activeFormat.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }
                device.unlockForConfiguration()
            } catch {
                // Není kritické, pokračujeme dál
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }

    // MARK: - Manuální zámek parametrů

    /// Zamkne ohnisko na danou pozici (0 = nejblíž, 1 = nejdál / nekonečno)
    func lockFocus(lensPosition: Float, completion: ((Bool) -> Void)? = nil) {
        guard let device = device else { completion?(false); return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                guard device.isFocusModeSupported(.locked) else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                device.setFocusModeLocked(lensPosition: lensPosition) { _ in
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { completion?(true) }
                }
            } catch {
                self.report(error: "Zámek ohniska selhal: \(error.localizedDescription)")
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    /// Zamkne expozici na dané ISO a čas závěrky (v sekundách)
    func lockExposure(iso: Float, durationSeconds: Double, completion: ((Bool) -> Void)? = nil) {
        guard let device = device else { completion?(false); return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                guard device.isExposureModeSupported(.custom) else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                let requested = CMTimeMakeWithSeconds(durationSeconds, preferredTimescale: 1_000_000)
                let minD = device.activeFormat.minExposureDuration
                let maxD = device.activeFormat.maxExposureDuration
                let clampedDuration = requested < minD ? minD : (requested > maxD ? maxD : requested)

                device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO) { _ in
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { completion?(true) }
                }
            } catch {
                self.report(error: "Zámek expozice selhal: \(error.localizedDescription)")
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    /// Zamkne bílý balanc na aktuální gainy zařízení
    func lockWhiteBalance(completion: ((Bool) -> Void)? = nil) {
        guard let device = device else { completion?(false); return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                guard device.isWhiteBalanceModeSupported(.locked) else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                let currentGains = device.deviceWhiteBalanceGains
                let clamped = self.clampGains(currentGains, for: device)
                device.setWhiteBalanceModeLocked(with: clamped) { _ in
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { completion?(true) }
                }
            } catch {
                self.report(error: "Zámek bílého balancu selhal: \(error.localizedDescription)")
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    private func clampGains(_ gains: AVCaptureDevice.WhiteBalanceGains, for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var g = gains
        let maxGain = device.maxWhiteBalanceGain
        g.redGain = min(max(1.0, g.redGain), maxGain)
        g.greenGain = min(max(1.0, g.greenGain), maxGain)
        g.blueGain = min(max(1.0, g.blueGain), maxGain)
        return g
    }

    /// Provede zámek expozice, ohniska a bílého balancu najednou
    func lockAll(iso: Float, durationSeconds: Double, lensPosition: Float) {
        lockExposure(iso: iso, durationSeconds: durationSeconds) { [weak self] expOk in
            guard let self = self else { return }
            self.lockFocus(lensPosition: lensPosition) { focusOk in
                self.lockWhiteBalance { wbOk in
                    self.sessionQueue.async {
                        if let device = self.device {
                            self.lockedISO = device.iso
                            self.lockedExposureDurationSeconds = device.exposureDuration.seconds
                            self.lockedLensPosition = device.lensPosition
                        }
                    }
                    DispatchQueue.main.async {
                        self.isLocked = expOk && focusOk && wbOk
                        if !self.isLocked {
                            self.report(error: "Některý ze zámků se nepodařil - zkontroluj podporu zařízení.")
                        }
                    }
                }
            }
        }
    }

    func unlockAll() {
        guard let device = device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isLocked = false }
            } catch {
                self.report(error: "Odemčení selhalo: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sériové snímání v nastavené frekvenci

    func startSeriesCapture(count: Int, intervalSeconds: Double) {
        guard isLocked else {
            report(error: "Parametry nejsou zamčené, snímání nelze spustit.")
            return
        }
        guard !isCapturing else { return }

        let folder = createCaptureFolder()

        sessionQueue.async {
            self.captureFolderURL = folder
            self.internalCapturedCount = 0
            self.internalTargetCount = count
            self.isPhotoInFlight = false
            self.metadataLog = []

            DispatchQueue.main.async {
                self.capturedCount = 0
                self.targetCount = count
                self.captureIntervalSeconds = intervalSeconds
                self.droppedFrames = 0
                self.isCapturing = true
            }

            let timer = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            timer.schedule(deadline: .now(), repeating: intervalSeconds, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                self?.tickCapture()
            }
            self.captureTimer = timer
            timer.resume()
        }
    }

    func stopSeriesCapture() {
        captureTimer?.cancel()
        captureTimer = nil

        sessionQueue.async {
            let folder = self.captureFolderURL
            let log = self.metadataLog
            self.metadataLog = []

            if let folder = folder {
                self.writeMetadata(log, to: folder)
            }

            DispatchQueue.main.async {
                self.isCapturing = false
                if let folder = folder {
                    self.onSeriesFinished?(folder)
                }
            }
        }
    }

    /// Volá se na sessionQueue v zadané frekvenci
    private func tickCapture() {
        if internalCapturedCount >= internalTargetCount {
            stopSeriesCapture()
            return
        }
        if isPhotoInFlight {
            // Předchozí snímek se ještě nezpracoval - frekvence je vyšší než reálná průběžnost.
            DispatchQueue.main.async { self.droppedFrames += 1 }
            return
        }
        isPhotoInFlight = true
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true
        settings.flashMode = .off
        if #available(iOS 13.0, *) {
            settings.photoQualityPrioritization = .quality
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func createCaptureFolder() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "scan_\(formatter.string(from: Date()))"
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeMetadata(_ log: [FrameMetadata], to folder: URL) {
        do {
            let data = try JSONEncoder().encode(log)
            let url = folder.appendingPathComponent("metadata.json")
            try data.write(to: url)
        } catch {
            report(error: "Uložení metadat selhalo: \(error.localizedDescription)")
        }
    }

    private func report(error: String) {
        DispatchQueue.main.async {
            self.lastError = error
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            sessionQueue.async { self.isPhotoInFlight = false }
            report(error: "Snímek se nepodařilo zpracovat: \(error?.localizedDescription ?? "neznámá chyba")")
            return
        }

        sessionQueue.async {
            guard let folder = self.captureFolderURL else {
                self.isPhotoInFlight = false
                return
            }
            let index = self.internalCapturedCount
            let filename = String(format: "frame_%04d.heic", index)
            let url = folder.appendingPathComponent(filename)

            do {
                try data.write(to: url)

                let meta = FrameMetadata(
                    index: index,
                    timestamp: Date().timeIntervalSince1970,
                    iso: self.lockedISO,
                    exposureDurationSeconds: self.lockedExposureDurationSeconds,
                    lensPosition: self.lockedLensPosition
                )
                self.metadataLog.append(meta)

                self.internalCapturedCount += 1
                let newCount = self.internalCapturedCount
                DispatchQueue.main.async {
                    self.capturedCount = newCount
                }
            } catch {
                self.report(error: "Uložení snímku selhalo: \(error.localizedDescription)")
            }
            self.isPhotoInFlight = false
        }
    }
}
