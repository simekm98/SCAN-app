import SwiftUI
import ARKit
import RealityKit

struct ARScanView: View {
    @StateObject private var session = ARScanSession()

    @State private var stepMM: Double = 50.0
    @State private var showSettings = false
    @State private var lastFinishedFolder: URL? = nil
    @State private var showFinishedAlert = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // ARKit náhled
            ARViewContainer(arSession: session.arSession)
                .ignoresSafeArea()

            // HUD přes náhled
            VStack(spacing: 0) {
                statusBar
                Spacer()
                depthIndicator
                controlPanel
            }
        }
        .onAppear {
            session.stepMM = Float(stepMM)
            session.onScanFinished = { folder in
                lastFinishedFolder = folder
                showFinishedAlert = true
            }
            session.startSession()
        }
        .onDisappear { session.stopSession() }
        .alert("Sken dokončen", isPresented: $showFinishedAlert) {
            Button("OK") {}
        } message: {
            Text("Uloženo \(session.capturedFrameCount) snímků do:\n\(lastFinishedFolder?.lastPathComponent ?? "")")
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack {
            trackingIndicator
            Spacer()
            if let error = session.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.yellow)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.white)
                    .padding(10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .background(.black.opacity(0.5))
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    private var trackingIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(trackingColor)
                .frame(width: 10, height: 10)
            Text(trackingLabel)
                .font(.caption)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4))
        .cornerRadius(20)
    }

    private var depthIndicator: some View {
        Group {
            if let dist = session.currentBoardDistanceM {
                HStack(spacing: 4) {
                    Image(systemName: "ruler")
                        .foregroundColor(.cyan)
                    Text(String(format: "%.0f mm", dist * 1000))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.cyan)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6))
                .cornerRadius(12)
                .padding(.bottom, 8)
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            if case .scanning = session.state {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .foregroundColor(.green)
                    Text("\(session.capturedFrameCount) snímků")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.white)
                    Text("• každých \(Int(stepMM)) mm")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            HStack(spacing: 20) {
                mainButton
            }
        }
        .padding()
        .background(.black.opacity(0.7))
    }

    private var mainButton: some View {
        Group {
            switch session.state {
            case .idle, .initializing:
                Button("Čekám na tracking...") {}
                    .disabled(true)
                    .buttonStyle(.bordered)

            case .tracking:
                Button {
                    session.stepMM = Float(stepMM)
                    session.startScan()
                } label: {
                    Label("Spustit sken", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

            case .scanning:
                Button {
                    session.stopScan()
                } label: {
                    Label("Zastavit", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

            case .paused:
                Button("Pozastaveno") {}
                    .disabled(true)
                    .buttonStyle(.bordered)

            case .failed(let msg):
                Text("Chyba: \(msg)")
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section("Prostorový krok extrakce") {
                    VStack(alignment: .leading) {
                        Text("Krok: \(Int(stepMM)) mm")
                        Slider(value: $stepMM, in: 10...200, step: 5)
                    }
                }
                Section("Info") {
                    LabeledContent("Tracking", value: trackingLabel)
                    if let dist = session.currentBoardDistanceM {
                        LabeledContent("Vzdálenost desky", value: String(format: "%.1f mm", dist * 1000))
                    }
                    LabeledContent("Zachyceno snímků", value: "\(session.capturedFrameCount)")
                }
            }
            .navigationTitle("Nastavení skenu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { showSettings = false }
                }
            }
        }
    }

    // MARK: - Helpers

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

// MARK: - ARView wrapper (RealityKit ARView napojený na existující ARSession)

struct ARViewContainer: UIViewRepresentable {
    let arSession: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = arSession
        view.renderOptions = [.disableDepthOfField, .disableMotionBlur,
                              .disableHDR, .disableFaceMesh, .disablePersonOcclusion]
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
