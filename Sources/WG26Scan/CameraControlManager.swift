import Foundation
import AVFoundation
import UIKit

/// Spravuje manuální parametry kamery.
/// - Změny ISO a závěrky se aplikují OKAMŽITĚ na zařízení → živý náhled.
/// - Ohnisko: tap na scénu → auto-focus na bod → appka přečte výslednou pozici,
///   ale nestahuje do .locked módu (ten rozbíjí ARKit LiDAR).
/// - Bez přepínání objektivů – vždy 1× hlavní kamera.
final class CameraControlManager: ObservableObject {

    @Published var iso: Float = 100
    @Published var shutterSpeed: ShutterSpeed = ShutterSpeed.presets[3]  // 1/500
    @Published var lensPosition: Float = 0.5
    @Published var isLocked: Bool = false
    @Published var statusMessage: String = ""
    @Published var focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var showFocusIndicator: Bool = false

    @Published var minISO: Float = 32
    @Published var maxISO: Float = 3200

    private let q = DispatchQueue(label: "wg26.camera.ctrl", qos: .userInteractive)

    private var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    init() {
        q.async { [weak self] in
            guard let self = self, let dev = self.device else { return }
            let mn = dev.activeFormat.minISO
            let mx = dev.activeFormat.maxISO
            let cur = dev.iso
            let pos = dev.lensPosition
            DispatchQueue.main.async {
                self.minISO = mn; self.maxISO = mx
                self.iso = cur; self.lensPosition = pos
            }
        }
    }

    // MARK: - Okamžitá aplikace na živý náhled

    /// Voláno při každém pohybu slideru ISO → ihned viditelné v ARKit náhledu.
    func applyISO(_ newISO: Float) {
        iso = newISO
        applyExposureRaw(iso: newISO, durationSeconds: shutterSpeed.seconds)
    }

    /// Voláno při výběru času závěrky → ihned viditelné.
    func applyShutter(_ ss: ShutterSpeed) {
        shutterSpeed = ss
        applyExposureRaw(iso: iso, durationSeconds: ss.seconds)
    }

    private func applyExposureRaw(iso: Float, durationSeconds: Double) {
        guard let dev = device else { return }
        q.async {
            do {
                try dev.lockForConfiguration()
                guard dev.isExposureModeSupported(.custom) else {
                    dev.unlockForConfiguration(); return
                }
                // HDR musí být vypnuté jinak přebíjí manuální hodnoty
                if dev.activeFormat.isVideoHDRSupported {
                    dev.automaticallyAdjustsVideoHDREnabled = false
                    dev.isVideoHDREnabled = false
                }
                let minD = dev.activeFormat.minExposureDuration
                let maxD = dev.activeFormat.maxExposureDuration
                let req  = CMTimeMakeWithSeconds(durationSeconds, preferredTimescale: 1_000_000)
                let dur  = req < minD ? minD : (req > maxD ? maxD : req)
                let clampedISO = min(max(iso, dev.activeFormat.minISO), dev.activeFormat.maxISO)
                dev.setExposureModeCustom(duration: dur, iso: clampedISO) { _ in }
                dev.unlockForConfiguration()
            } catch { }
        }
    }

    // MARK: - Tap-to-focus (bez tvrdého .locked – ARKit zůstane stabilní)

    func tapToFocus(at normalizedPoint: CGPoint) {
        guard let dev = device else { return }
        focusPoint = normalizedPoint
        showFocusIndicator = true

        q.async {
            do {
                try dev.lockForConfiguration()
                // AVFoundation: y je od dolní hrany
                let avPt = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
                if dev.isFocusPointOfInterestSupported && dev.isFocusModeSupported(.autoFocus) {
                    dev.focusPointOfInterest = avPt
                    dev.focusMode = .autoFocus   // zaostří jednou a zůstane (ne .locked)
                }
                dev.unlockForConfiguration()

                // Po doběhnutí auto-focusu přečteme výslednou pozici
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.lensPosition = dev.lensPosition
                    self.showFocusIndicator = false
                }
            } catch { }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.showFocusIndicator = false
        }
    }

    // MARK: - Zamknutí bílého balancu + zápis stavu

    func lockWhiteBalance(completion: (() -> Void)? = nil) {
        guard let dev = device else { return }
        q.async {
            do {
                try dev.lockForConfiguration()
                if dev.isWhiteBalanceModeSupported(.locked) {
                    var g = dev.deviceWhiteBalanceGains
                    let mg = dev.maxWhiteBalanceGain
                    g.redGain   = min(max(g.redGain,   1.0), mg)
                    g.greenGain = min(max(g.greenGain, 1.0), mg)
                    g.blueGain  = min(max(g.blueGain,  1.0), mg)
                    dev.setWhiteBalanceModeLocked(with: g) { _ in }
                }
                dev.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.isLocked = true
                    self.statusMessage = "Zamčeno: ISO \(Int(self.iso)), \(self.shutterSpeed.display)"
                    completion?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Chyba: \(error.localizedDescription)"
                }
            }
        }
    }

    func lockAll() {
        // Expozice + ISO jsou již aplikovány průběžně.
        // Uzamkneme jen bílý balanc a nastavíme příznak.
        lockWhiteBalance()
    }

    func unlockAll() {
        guard let dev = device else { return }
        q.async {
            do {
                try dev.lockForConfiguration()
                if dev.isExposureModeSupported(.continuousAutoExposure) {
                    dev.exposureMode = .continuousAutoExposure
                }
                if dev.isFocusModeSupported(.continuousAutoFocus) {
                    dev.focusMode = .continuousAutoFocus
                }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    dev.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                dev.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.isLocked = false
                    self.statusMessage = "Automatický režim"
                }
            } catch { }
        }
    }
}
