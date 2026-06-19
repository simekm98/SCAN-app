import SwiftUI
import ARKit
import RealityKit

struct ARScanView: View {
    @StateObject private var session      = ARScanSession()
    @StateObject private var camera       = CameraControlManager()
    @StateObject private var voice        = VoiceCommandManager()

    @State private var activeParam: ActiveParam = .none
    @State private var captureMode: CaptureMode = .spatial
    @State private var stepMM: Double  = 50.0
    @State private var captureHz: Double = 1.0
    @State private var stopMode: Int   = 0
    @State private var stopDistanceMM: Double = 2000
    @State private var stopFrameCount: Int = 100

    @State private var showAlert    = false
    @State private var alertMessage = ""
    @State private var showFinished = false
    @State private var finishedFolder: URL? = nil

    var body: some View {
        ZStack {
            // ARKit náhled + tap-to-focus
            ARViewWrapper(arSession: session.arSession, camera: camera)
                .ignoresSafeArea()

            // Focus křížek
            if camera.showFocusIndicator {
                FocusCrosshair()
                    .position(
                        x: camera.focusPoint.x * UIScreen.main.bounds.width,
                        y: camera.focusPoint.y * UIScreen.main.bounds.height
                    )
            }

            // HUD
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .onAppear {
            voice.requestPermissions()
            voice.onCommand = handleVoiceCommand
            applySettings()
            session.onScanFinished = { folder in
                finishedFolder = folder; showFinished = true
            }
            session.startSession()
        }
        .onDisappear { voice.stopListening(); session.stopSession() }
        .alert(alertMessage, isPresented: $showAlert) { Button("OK") {} }
        .alert("Sken dokončen", isPresented: $showFinished) { Button("OK") {} } message: {
            Text("\(session.capturedFrameCount) snímků\n\(finishedFolder?.lastPathComponent ?? "")")
        }
    }

    // MARK: - Top bar (bez mikrofonu, bez objektivů)

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle().fill(trackingColor).frame(width: 10, height: 10)

            if let d = session.currentBoardDistanceM {
                Text(String(format: "%.0f mm", d * 1000))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.cyan)
            }

            Spacer()

            // Zámek ikona
            Image(systemName: camera.isLocked ? "lock.fill" : "lock.open.fill")
                .foregroundColor(camera.isLocked ? .green : .orange)

            // Stav trackingu
            Text(trackingLabel)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55))
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if case .scanning = session.state { scanProgressBar.padding(.horizontal, 14).padding(.vertical, 6) }

            if activeParam != .none { paramPicker.transition(.move(edge: .bottom).combined(with: .opacity)) }

            paramStrip

            if activeParam == .stopCondition { stopConditionPanel }

            mainControls.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .background(.black.opacity(0.75))
        .animation(.easeInOut(duration: 0.2), value: activeParam)
    }

    // MARK: - Param strip

    private var paramStrip: some View {
        HStack(spacing: 0) {
            paramCell(label: "ISO", value: "\(Int(camera.iso))", param: .iso)
            divider
            paramCell(label: "SS",  value: camera.shutterSpeed.display, param: .shutter)
            divider
            paramCell(label: "FOCUS", value: String(format: "%.2f", camera.lensPosition), param: .focus)
            divider
            paramCell(label: "STOP", value: stopLabel, param: .stopCondition)
        }
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle().frame(width: 1, height: 30).foregroundColor(.white.opacity(0.2))
    }

    private func paramCell(label: String, value: String, param: ActiveParam) -> some View {
        Button { withAnimation { activeParam = (activeParam == param) ? .none : param } } label: {
            VStack(spacing: 2) {
                Text(label).font(.system(size: 9)).foregroundColor(activeParam == param ? .yellow : .gray)
                Text(value).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundColor(.white)
            }.frame(maxWidth: .infinity)
        }
    }

    // MARK: - Picker

    @ViewBuilder
    private var paramPicker: some View {
        switch activeParam {
        case .iso:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach([32, 50, 100, 200, 400, 800, 1600, 3200], id: \.self) { val in
                        chip(label: "\(val)", selected: Int(camera.iso) == val) {
                            camera.applyISO(Float(val))   // okamžitý živý náhled
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 44).background(Color.black.opacity(0.6))

        case .shutter:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ShutterSpeed.presets) { ss in
                        chip(label: ss.display, selected: camera.shutterSpeed.display == ss.display) {
                            camera.applyShutter(ss)   // okamžitý živý náhled
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 44).background(Color.black.opacity(0.6))

        case .focus:
            VStack(spacing: 4) {
                Text("Ťukni na scénu → kamera zaostří na daný bod")
                    .font(.caption2).foregroundColor(.yellow)
                HStack {
                    Text("Pozice: \(String(format: "%.2f", camera.lensPosition))")
                        .font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                    Spacer()
                    Button("Zavřít") { withAnimation { activeParam = .none } }
                        .font(.caption2).buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 8).background(Color.black.opacity(0.6))

        case .stopCondition:
            EmptyView()

        default:
            EmptyView()
        }
    }

    // MARK: - Stop condition

    private var stopConditionPanel: some View {
        VStack(spacing: 8) {
            Picker("Stop", selection: $stopMode) {
                Text("Manuálně").tag(0)
                Text("Vzdálenost").tag(1)
                Text("Počet snímků").tag(2)
            }
            .pickerStyle(.segmented).padding(.horizontal, 14)

            if stopMode == 1 {
                HStack {
                    Text("Stop po:").font(.caption).foregroundColor(.gray)
                    Spacer()
                    Text("\(Int(stopDistanceMM)) mm").font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                }.padding(.horizontal, 14)
                Slider(value: $stopDistanceMM, in: 500...5000, step: 100).padding(.horizontal, 14)
            } else if stopMode == 2 {
                HStack {
                    Text("Stop po:").font(.caption).foregroundColor(.gray)
                    Spacer()
                    Text("\(stopFrameCount) snímků").font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                }.padding(.horizontal, 14)
                Stepper("", value: $stopFrameCount, in: 10...2000, step: 10).padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8).background(Color.black.opacity(0.6))
    }

    // MARK: - Progress bar

    private var scanProgressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "camera.fill").foregroundColor(.green).font(.caption)
                Text("\(session.capturedFrameCount) snímků")
                    .font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                Spacer()
                if stopMode == 1 {
                    Text("\(Int(session.totalDistanceMM)) / \(Int(stopDistanceMM)) mm")
                        .font(.system(.caption2, design: .monospaced)).foregroundColor(.cyan)
                } else if stopMode == 2 {
                    Text("\(session.capturedFrameCount) / \(stopFrameCount)")
                        .font(.system(.caption2, design: .monospaced)).foregroundColor(.cyan)
                }
            }
            if stopMode != 0 {
                let p: Double = stopMode == 1
                    ? Double(session.totalDistanceMM) / stopDistanceMM
                    : Double(session.capturedFrameCount) / Double(stopFrameCount)
                ProgressView(value: min(p, 1.0)).tint(.green)
            }
        }
    }

    // MARK: - Hlavní ovládací lišta

    private var mainControls: some View {
        HStack(spacing: 16) {

            // Zamknout / Odemknout
            Button {
                camera.isLocked ? camera.unlockAll() : camera.lockAll()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: camera.isLocked ? "lock.open.fill" : "lock.fill")
                        .font(.title2)
                        .foregroundColor(camera.isLocked ? .orange : .green)
                    Text(camera.isLocked ? "Odemknout" : "Zamknout")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
                .frame(width: 60)
            }

            // Start / Stop (velké tlačítko uprostřed)
            Button {
                switch session.state {
                case .tracking:
                    guard camera.isLocked else {
                        alertMessage = "Nejdřív zamkni parametry kamery."
                        showAlert = true
                        return
                    }
                    applySettings(); session.startScan()
                case .scanning:
                    session.stopScan()
                default: break
                }
            } label: {
                ZStack {
                    Circle().fill(scanBtnColor).frame(width: 70, height: 70)
                    if case .scanning = session.state {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white).frame(width: 24, height: 24)
                    } else {
                        Circle().fill(Color.white).frame(width: 60, height: 60)
                    }
                }
            }
            .disabled(!(session.state == .tracking || session.state == .scanning))

            // Hlasové povely – ťuknutím zapnout/vypnout
            Button {
                if voice.isListening { voice.stopListening() }
                else { voice.startListening() }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: voice.isListening ? "waveform.circle.fill" : "waveform.circle")
                        .font(.title2)
                        .foregroundColor(voice.isListening ? .green : .gray)
                    Text(voice.isListening ? "Hlas ON" : "Hlas OFF")
                        .font(.system(size: 9))
                        .foregroundColor(voice.isListening ? .green : .gray)
                }
                .frame(width: 60)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Helpers

    private var scanBtnColor: Color {
        switch session.state {
        case .scanning: return .red.opacity(0.8)
        case .tracking: return .green.opacity(0.8)
        default:        return .gray.opacity(0.5)
        }
    }

    private var trackingColor: Color {
        switch session.trackingQuality {
        case .normal:       return .green
        case .limited:      return .yellow
        case .notAvailable: return .red
        @unknown default:   return .gray
        }
    }

    private var trackingLabel: String {
        switch session.state {
        case .idle:         return "Idle"
        case .initializing: return "Init..."
        case .tracking:     return "OK"
        case .scanning:     return "Scan"
        case .paused:       return "Pause"
        case .failed:       return "Err"
        }
    }

    private var stopLabel: String {
        switch stopMode {
        case 1: return "\(Int(stopDistanceMM))mm"
        case 2: return "\(stopFrameCount)fr"
        default: return "Man."
        }
    }

    private func applySettings() {
        session.captureMode = captureMode
        session.stepMM      = Float(stepMM)
        session.captureHz   = captureHz
        switch stopMode {
        case 1:  session.stopCondition = .distance(mm: Float(stopDistanceMM))
        case 2:  session.stopCondition = .frameCount(stopFrameCount)
        default: session.stopCondition = .manual
        }
    }

    private func handleVoiceCommand(_ cmd: VoiceCommand) {
        switch cmd {
        case .start:
            guard camera.isLocked else {
                alertMessage = "Hlasový START: nejdřív zamkni parametry."
                showAlert = true
                return
            }
            if case .tracking = session.state { applySettings(); session.startScan() }
        case .stop:
            if case .scanning = session.state { session.stopScan() }
        case .lock:   camera.lockAll()
        case .unlock: camera.unlockAll()
        case .unknown: break
        }
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.yellow : Color.white.opacity(0.15))
                .foregroundColor(selected ? .black : .white)
                .cornerRadius(6)
        }
    }
}

// MARK: - ARView wrapper s tap gesture

struct ARViewWrapper: UIViewRepresentable {
    let arSession: ARSession
    let camera: CameraControlManager

    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        v.session = arSession
        v.renderOptions = [.disableDepthOfField, .disableMotionBlur, .disableHDR,
                           .disableFaceMesh, .disablePersonOcclusion]
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(tap)
        return v
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    final class Coordinator: NSObject {
        let camera: CameraControlManager
        init(camera: CameraControlManager) { self.camera = camera }
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            let pt = g.location(in: v)
            camera.tapToFocus(at: CGPoint(x: pt.x / v.bounds.width, y: pt.y / v.bounds.height))
        }
    }
}

// MARK: - Focus křížek

struct FocusCrosshair: View {
    @State private var scale: CGFloat = 1.2
    var body: some View {
        ZStack {
            Rectangle().frame(width: 40, height: 1).foregroundColor(.yellow)
            Rectangle().frame(width: 1, height: 40).foregroundColor(.yellow)
            Rectangle().stroke(Color.yellow, lineWidth: 1.5).frame(width: 50, height: 50)
        }
        .scaleEffect(scale)
        .onAppear { withAnimation(.easeOut(duration: 0.3)) { scale = 1.0 } }
    }
}

// MARK: - ScanSessionState Equatable

extension ScanSessionState: Equatable {
    static func == (lhs: ScanSessionState, rhs: ScanSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle,.idle), (.initializing,.initializing), (.tracking,.tracking),
             (.scanning,.scanning), (.paused,.paused): return true
        default: return false
        }
    }
}
