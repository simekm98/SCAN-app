import Foundation
import AVFoundation
import UIKit

final class CameraControlManager: ObservableObject {

    // MARK: - Publikované hodnoty

    @Published var iso: Float = 100
    @Published var shutterSpeed: ShutterSpeed = ShutterSpeed.presets[3] // 1/500
    @Published var lensPosition: Float = 0.5
    @Published var lensType: LensType = .wide
    @Published var isLocked: Bool = false
    @Published var statusMessage: String = ""

    // Rozsahy zařízení
    @Published var minISO: Float = 32
    @Published var maxISO: Float = 3200

    // Aktuální focus point (normalized 0-1 pro zobrazení křížku)
    @Published var focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var showFocusIndicator: Bool = false

    private let sessionQueue = DispatchQueue(label: "wg26.camera.control")

    private var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    init() {
        sessionQueue.async { [weak self] in
            guard let self = self, let dev = self.device else { return }
            let minISO = dev.activeFormat.minISO
            let maxISO = dev.activeFormat.maxISO
            let currentISO = dev.iso
            let currentLens = dev.lensPosition
            DispatchQueue.main.async {
                self.minISO = minISO
                self.maxISO = maxISO
                self.iso = currentISO
                self.lensPosition = currentLens
            }
        }
    }

    // MARK: - Tap to focus

    /// Volej s normalizovanými souřadnicemi 0-1 (x=0 vlevo, y=0 nahoře)
    func tapToFocus(at normalizedPoint: CGPoint) {
        guard let device = device else { return }
        focusPoint = normalizedPoint
        showFocusIndicator = true

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                // Nejdřív auto-focus na daném bodě
                if device.isFocusPointOfInterestSupported &&
                   device.isFocusModeSupported(.autoFocus) {
                    // AVFoundation má obrácené souřadnice (y od dolní strany)
                    let avPoint = CGPoint(x: normalizedPoint.x,
                                         y: 1.0 - normalizedPoint.y)
                    device.focusPointOfInterest = avPoint
                    device.focusMode = .autoFocus
                }
                device.unlockForConfiguration()

                // Po auto-focusu počkáme 0.5s a zamkneme
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.lockFocusAtCurrentPosition()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Chyba focus: \(error.localizedDescription)"
                }
            }
        }

        // Skrýt indikátor po 2s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.showFocusIndicator = false
        }
    }

    private func lockFocusAtCurrentPosition() {
        guard let device = device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: AVCaptureDevice.currentLensPosition) { _ in
                        DispatchQueue.main.async {
                            self.lensPosition = device.lensPosition
                        }
                    }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    // MARK: - Zoom

    func setZoom(_ lensType: LensType) {
        guard let device = device else { return }
        self.lensType = lensType
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let maxZoom = device.activeFormat.videoMaxZoomFactor
                let factor = min(CGFloat(lensType.zoomFactor), maxZoom)
                device.videoZoomFactor = max(1.0, factor)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    // MARK: - Zámek všech parametrů

    func lockAll(completion: ((Bool) -> Void)? = nil) {
        guard let device = device else {
            setStatus("Kamera nenalezena.")
            completion?(false)
            return
        }

        let targetISO = iso
        let targetSS = shutterSpeed

        sessionQueue.async {
            do {
                try device.lockForConfiguration()

                // Expozice + ISO
                if device.isExposureModeSupported(.custom) {
                    let minD = device.activeFormat.minExposureDuration
                    let maxD = device.activeFormat.maxExposureDuration
                    let requested = CMTimeMakeWithSeconds(targetSS.seconds, preferredTimescale: 1_000_000)
                    let clamped: CMTime
                    if requested < minD { clamped = minD }
                    else if requested > maxD { clamped = maxD }
                    else { clamped = requested }
                    let clampedISO = min(max(targetISO, device.activeFormat.minISO), device.activeFormat.maxISO)
                    device.setExposureModeCustom(duration: clamped, iso: clampedISO) { _ in }
                }

                // Bílý balanc
                if device.isWhiteBalanceModeSupported(.locked) {
                    var gains = device.deviceWhiteBalanceGains
                    let mg = device.maxWhiteBalanceGain
                    gains.redGain   = min(max(gains.redGain,   1.0), mg)
                    gains.greenGain = min(max(gains.greenGain, 1.0), mg)
                    gains.blueGain  = min(max(gains.blueGain,  1.0), mg)
                    device.setWhiteBalanceModeLocked(with: gains) { _ in }
                }

                // HDR vypnout
                if device.activeFormat.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }

                device.unlockForConfiguration()

                // Ohnisko zamknout na aktuální pozici
                self.lockFocusAtCurrentPosition()

                DispatchQueue.main.async {
                    self.isLocked = true
                    self.setStatus("Zamčeno: ISO \(Int(targetISO)), \(targetSS.display)")
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("Chyba zámku: \(error.localizedDescription)")
                    completion?(false)
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
                DispatchQueue.main.async {
                    self.isLocked = false
                    self.setStatus("Automatický režim")
                }
            } catch { }
        }
    }

    private func setStatus(_ msg: String) {
        DispatchQueue.main.async { self.statusMessage = msg }
    }
}
