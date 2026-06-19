import Foundation
import AVFoundation
import ARKit

/// Zamyká parametry kamery (ISO, expozice, ohnisko, bílý balanc) na zařízení,
/// které ARKit interně používá. ARKit session může stále běžet – zámek funguje
/// i souběžně, jen hloubková mapa může mít o trochu nižší confidence při
/// zamčeném ohnisku (pro scan řeziva na fixní vzdálenosti je to akceptovatelné).
final class CameraControlManager: ObservableObject {

    // MARK: - Publikované hodnoty (pro UI slidery)

    @Published var iso: Float = 100
    @Published var exposureMs: Double = 8.0
    @Published var lensPosition: Float = 0.5
    @Published var isLocked: Bool = false
    @Published var statusMessage: String = ""

    // Rozsahy zařízení (načtou se při inicializaci)
    @Published var minISO: Float = 32
    @Published var maxISO: Float = 3200
    @Published var minExposureMs: Double = 0.5
    @Published var maxExposureMs: Double = 50.0

    private let sessionQueue = DispatchQueue(label: "wg26.camera.control")

    private var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    init() {
        sessionQueue.async { [weak self] in
            guard let self = self, let dev = self.device else { return }
            let minISO = dev.activeFormat.minISO
            let maxISO = dev.activeFormat.maxISO
            let minExpMs = dev.activeFormat.minExposureDuration.seconds * 1000
            let maxExpMs = min(dev.activeFormat.maxExposureDuration.seconds * 1000, 100)
            let currentISO = dev.iso
            let currentExpMs = dev.exposureDuration.seconds * 1000
            let currentLens = dev.lensPosition
            DispatchQueue.main.async {
                self.minISO = minISO
                self.maxISO = maxISO
                self.minExposureMs = minExpMs
                self.maxExposureMs = maxExpMs
                self.iso = currentISO
                self.exposureMs = currentExpMs
                self.lensPosition = currentLens
            }
        }
    }

    // MARK: - Zámek všech parametrů najednou

    func lockAll(completion: ((Bool) -> Void)? = nil) {
        guard let device = device else {
            setStatus("Kamera nenalezena.")
            completion?(false)
            return
        }

        let targetISO = iso
        let targetExpMs = exposureMs
        let targetLens = lensPosition

        sessionQueue.async {
            do {
                try device.lockForConfiguration()

                // 1. Expozice + ISO
                if device.isExposureModeSupported(.custom) {
                    let minD = device.activeFormat.minExposureDuration
                    let maxD = device.activeFormat.maxExposureDuration
                    let requested = CMTimeMakeWithSeconds(targetExpMs / 1000.0, preferredTimescale: 1_000_000)
                    let clamped = min(max(requested, minD), maxD)
                    let clampedISO = min(max(targetISO, device.activeFormat.minISO), device.activeFormat.maxISO)
                    device.setExposureModeCustom(duration: clamped, iso: clampedISO) { _ in }
                }

                // 2. Ohnisko
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: targetLens) { _ in }
                }

                // 3. Bílý balanc – zamknout na aktuálních gainech
                if device.isWhiteBalanceModeSupported(.locked) {
                    var gains = device.deviceWhiteBalanceGains
                    let maxGain = device.maxWhiteBalanceGain
                    gains.redGain   = min(max(gains.redGain,   1.0), maxGain)
                    gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
                    gains.blueGain  = min(max(gains.blueGain,  1.0), maxGain)
                    device.setWhiteBalanceModeLocked(with: gains) { _ in }
                }

                // 4. Vypnout HDR
                if device.activeFormat.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }

                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.isLocked = true
                    self.setStatus("Zamčeno: ISO \(Int(targetISO)), \(String(format: "%.1f", targetExpMs)) ms, ohnisko \(String(format: "%.2f", targetLens))")
                    completion?(true)
                }
            } catch {
                device.unlockForConfiguration()
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
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("Chyba odemčení: \(error.localizedDescription)")
                }
            }
        }
    }

    private func setStatus(_ msg: String) {
        DispatchQueue.main.async { self.statusMessage = msg }
    }
}
