import SwiftUI
import ARKit
import RealityKit

struct ARScanView: View {
    @StateObject private var session = ARScanSession()
    @StateObject private var cameraControl = CameraControlManager()

    @State private var captureMode: CaptureMode = .spatial
    @State private var stepMM: Double = 50.0
    @State private var captureHz: Double = 1.0
    @State private var showSettings = false
    @State private var showFinishedAlert = false
    @State private var lastFinishedFolder: URL? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(arSession: session.arSession)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar
                Spacer()
                depthIndicator
                controlPanel
            }
        }
        .onAppear {
            applySettingsToSession()
            session.onScanFinished = { folder in
                lastFinishedFolder = folder
                showFinishedAlert = true
            }
            session.startSession()
        }
        .onDisappear { session.stopSession() }
        .sheet(isPresented: $showSettings, onDismiss: applySettingsToSession) {
            CameraSettingsView(
                cameraControl: cameraControl,
                captureMode: $captureMode,
                stepMM: $stepMM,
                captureHz: $captureHz
            )
        }
        .alert("Sken dokončen", isPresented: $showFinishedAlert) {
            Button("OK") {}
        } message: {
            Text("Uloženo \(session.capturedFrameCount) snímků\n\(lastFinishedFolder?.lastPathComponent ?? "")")
        }
    }

    private func applySettingsToSession() {
        session.captureMode = captureMode
        session.stepMM = Float(stepMM)
        session.captureHz = captureHz
    }

    // MARK: - UI komponenty

    private var statusBar: some View {
        HStack {
            trackingBadge
            Spacer()
            // Indikátor zámku kamery
            if cameraControl.isLocked {
                Image(systemName: "lock.fill")
                    .foregroundColor(.green)
                    .padding(6)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
            }
            // Mód snímání badge
            Text(captureMode == .spatial ? "\(Int(stepMM)) mm" : "\(String(format: "%.1f", captureHz)) Hz")
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.4))
                .cornerRadius(8)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.white)
                    .padding(10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .background(.black.opacity(0.5))
    }

    private var trackingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(trackingColor).frame(width: 10, height: 10)
            Text(trackingLabel).font(.caption).foregroundColor(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.4)).cornerRadius(20)
    }

    private var depthIndicator: some View {
        Group {
            if let dist = session.currentBoardDistanceM {
                HStack(spacing: 4) {
                    Image(systemName: "ruler").foregroundColor(.cyan)
                    Text(String(format: "%.0f mm", dist * 1000))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.cyan)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.black.opacity(0.6)).cornerRadius(12)
                .padding(.bottom, 8)
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            if case .scanning = session.state {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill").foregroundColor(.green)
                    Text("\(session.capturedFrameCount) snímků")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            if let err = session.lastError {
                Text(err).font(.caption2).foregroundColor(.yellow).lineLimit(2)
            }
            mainButton
        }
        .padding()
        .background(.black.opacity(0.7))
    }

    private var mainButton: some View {
        Group {
            switch session.state {
            case .idle, .initializing:
                Button("Čekám na tracking...") {}
                    .disabled(true).buttonStyle(.bordered)
            case .tracking:
                Button {
                    applySettingsToSession()
                    session.startScan()
                } label: {
                    Label("Spustit sken", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            case .scanning:
                Button {
                    session.stopScan()
                } label: {
                    Label("Zastavit", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)
            case .paused:
                Button("Pozastaveno") {}.disabled(true).buttonStyle(.bordered)
            case .failed(let msg):
                Text("Chyba: \(msg)").foregroundColor(.red).font(.caption)
            }
        }
    }

    private var trackingColor: Color {
        switch session.trackingQuality {
        case .normal: return .green
        case .limited: return .yellow
        case .notAvailable: return .red
        @unknown default: return .gray
        }
    }

    private var trackingLabel: String {
        switch session.state {
        case .idle: return "Idle"
        case .initializing: return "Inicializace..."
        case .tracking: return "Tracking OK"
        case .scanning: return "Skenování"
        case .paused: return "Pozastaveno"
        case .failed: return "Chyba"
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arSession: ARSession
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = arSession
        view.renderOptions = [.disableDepthOfField, .disableMotionBlur, .disableHDR, .disableFaceMesh, .disablePersonOcclusion]
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
