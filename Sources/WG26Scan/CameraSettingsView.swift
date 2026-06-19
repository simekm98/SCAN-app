import SwiftUI

/// Mod vzorkování snímků
enum CaptureMode: String, CaseIterable {
    case spatial = "Prostorový (mm)"
    case temporal = "Časový (Hz)"
}

/// Plný panel nastavení kamery + módu snímání.
/// Používá se jako sheet z ARScanView.
struct CameraSettingsView: View {
    @ObservedObject var cameraControl: CameraControlManager
    @Binding var captureMode: CaptureMode
    @Binding var stepMM: Double
    @Binding var captureHz: Double

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                exposureSection
                focusSection
                captureModeSection
                statusSection
            }
            .navigationTitle("Nastavení kamery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sekce expozice

    private var exposureSection: some View {
        Section("Expozice") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("ISO")
                    Spacer()
                    Text("\(Int(cameraControl.iso))")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: $cameraControl.iso,
                    in: cameraControl.minISO...cameraControl.maxISO,
                    step: 1
                )
                .disabled(cameraControl.isLocked)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Čas závěrky")
                    Spacer()
                    Text("\(String(format: "%.1f", cameraControl.exposureMs)) ms")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: $cameraControl.exposureMs,
                    in: cameraControl.minExposureMs...cameraControl.maxExposureMs,
                    step: 0.1
                )
                .disabled(cameraControl.isLocked)
            }

            // Rychlé předvolby expozice
            HStack(spacing: 8) {
                Text("Předvolby:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach([
                    ("Tmavé", Float(200.0), 4.0),
                    ("Normální", Float(100.0), 8.0),
                    ("Světlé", Float(50.0), 16.0)
                ], id: \.0) { label, iso, ms in
                    Button(label) {
                        cameraControl.iso = iso
                        cameraControl.exposureMs = ms
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(cameraControl.isLocked)
                }
            }
        }
    }

    // MARK: - Sekce ohniska

    private var focusSection: some View {
        Section("Ohnisko") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pozice")
                    Spacer()
                    Text(focusLabel(cameraControl.lensPosition))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: $cameraControl.lensPosition,
                    in: 0...1,
                    step: 0.01
                )
                .disabled(cameraControl.isLocked)
            }

            // Rychlé předvolby vzdálenosti
            HStack(spacing: 8) {
                Text("Vzdálenost:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach([
                    ("20 cm", Float(0.3)),
                    ("40 cm", Float(0.5)),
                    ("60 cm", Float(0.65)),
                    ("∞", Float(1.0))
                ], id: \.0) { label, pos in
                    Button(label) {
                        cameraControl.lensPosition = pos
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(cameraControl.isLocked)
                }
            }

            Text("Tip: namiř telefon na desku ve skenovací vzdálenosti a nech auto-focus stabilizovat, pak zamkni.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Sekce módu snímání

    private var captureModeSection: some View {
        Section("Režim snímání") {
            Picker("Mód", selection: $captureMode) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if captureMode == .spatial {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Krok")
                        Spacer()
                        Text("\(Int(stepMM)) mm")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $stepMM, in: 5...200, step: 5)
                }
                Text("Snímek se zachytí pokaždé, když se telefon posune o daný počet mm (z ARKit odometrie).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Frekvence")
                        Spacer()
                        Text("\(String(format: "%.1f", captureHz)) Hz  (\(String(format: "%.0f", 1000/captureHz)) ms)")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $captureHz, in: 0.5...5.0, step: 0.5)
                }
                Text("Snímek se zachytí v pravidelných časových intervalech bez ohledu na pohyb.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Sekce stavu + tlačítka

    private var statusSection: some View {
        Section {
            if !cameraControl.statusMessage.isEmpty {
                Text(cameraControl.statusMessage)
                    .font(.caption)
                    .foregroundColor(cameraControl.isLocked ? .green : .secondary)
            }

            HStack(spacing: 12) {
                Button {
                    cameraControl.lockAll()
                } label: {
                    Label(
                        cameraControl.isLocked ? "Zamčeno" : "Zamknout",
                        systemImage: cameraControl.isLocked ? "lock.fill" : "lock.open"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(cameraControl.isLocked ? .green : .blue)
                .disabled(cameraControl.isLocked)

                Button {
                    cameraControl.unlockAll()
                } label: {
                    Label("Odemknout", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!cameraControl.isLocked)
            }
        }
    }

    // MARK: - Helpers

    private func focusLabel(_ pos: Float) -> String {
        switch pos {
        case 0..<0.2: return "Velmi blízko"
        case 0.2..<0.4: return "Blízko ~20cm"
        case 0.4..<0.6: return "Střed ~40cm"
        case 0.6..<0.8: return "Daleko ~60cm"
        default: return "Nekonečno"
        }
    }
}
