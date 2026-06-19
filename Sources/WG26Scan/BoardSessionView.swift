import SwiftUI

struct BoardSessionView: View {
    @StateObject private var store   = BoardScanStore()
    @StateObject private var session = ARScanSession()
    @StateObject private var camera  = CameraControlManager()
    @StateObject private var voice   = VoiceCommandManager()

    @State private var currentScan: BoardScan? = nil
    @State private var currentPhase: ScanPhase = .faceA

    @State private var showNameInput   = false
    @State private var boardName       = ""
    @State private var showList        = false
    @State private var showUnfolded    = false
    @State private var showAbortConfirm = false

    @State private var stitching       = false
    @State private var stitchProgress: Double = 0
    @State private var stitchMsg       = ""
    @State private var stitchPreview: UIImage? = nil
    @State private var showStitchPreview = false

    @State private var activeParam: ActiveParam = .none
    @State private var stepMM: Double = 50.0

    var body: some View {
        ZStack {
            ARViewWrapper(arSession: session.arSession, camera: camera)
                .ignoresSafeArea()

            if camera.showFocusIndicator {
                FocusCrosshair()
                    .position(x: camera.focusPoint.x * UIScreen.main.bounds.width,
                              y: camera.focusPoint.y * UIScreen.main.bounds.height)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if case .scanning = session.state { scanProgress }
                bottomPanel
            }

            if stitching { stitchOverlay }
        }
        .onAppear {
            voice.requestPermissions()
            voice.onCommand = handleVoice
            voice.startListening()
            session.startSession()
        }
        .onDisappear { voice.stopListening(); session.stopSession() }

        // Pojmenování
        .alert("Název desky", isPresented: $showNameInput) {
            TextField("např. KVH-001", text: $boardName)
            Button("Zrušit", role: .cancel) {}
            Button("Začít skenovat") { startNewBoard() }
                .disabled(boardName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Plochy se skenují v pořadí A → C → B → D")
        }

        // Stitch náhled + stop option
        .sheet(isPresented: $showStitchPreview) { stitchPreviewSheet }

        // Přerušit sken (potvrzení)
        .alert("Přerušit skenování?", isPresented: $showAbortConfirm) {
            Button("Přerušit a uložit rozdělanou práci") { abortScan(save: true) }
            Button("Přerušit a zahodit", role: .destructive) { abortScan(save: false) }
            Button("Pokračovat", role: .cancel) {}
        } message: {
            Text("Naskenované fáze budou zachovány nebo zahozeny dle volby.")
        }

        .sheet(isPresented: $showList)     { BoardScanListView(store: store) }
        .sheet(isPresented: $showUnfolded) {
            if let scan = currentScan { UnfoldedBoardView(scan: scan) }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle().fill(trackingColor).frame(width: 10, height: 10)

            if let d = session.currentBoardDistanceM {
                Text(String(format: "%.0f mm", d * 1000))
                    .font(.system(.caption, design: .monospaced)).foregroundColor(.cyan)
            }

            Spacer()

            if currentScan != nil {
                Text(currentPhase.displayName)
                    .font(.caption.bold()).foregroundColor(currentPhase.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(currentPhase.color.opacity(0.2)).cornerRadius(6)
            }

            Image(systemName: camera.isLocked ? "lock.fill" : "lock.open.fill")
                .foregroundColor(camera.isLocked ? .green : .orange)

            Button { showList = true } label: {
                Image(systemName: "list.bullet.rectangle").foregroundColor(.white)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.55))
    }

    // MARK: - Scan progress

    private var scanProgress: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(ScanPhase.allCases, id: \.self) { p in
                    let done = currentScan?.phases[p.rawValue].isComplete ?? false
                    let active = p == currentPhase
                    Circle()
                        .fill(done ? Color.green : active ? p.color : Color.gray.opacity(0.4))
                        .frame(width: active ? 12 : 8, height: active ? 12 : 8)
                    Text(p.shortName).font(.system(size: 9))
                        .foregroundColor(done ? .green : active ? p.color : .gray)
                }
            }
            Text("• \(session.capturedFrameCount) snímků")
                .font(.system(.caption, design: .monospaced)).foregroundColor(.white)
            Spacer()
            Text(currentScan?.displayName ?? "").font(.caption2).foregroundColor(.gray)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.black.opacity(0.6))
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if activeParam != .none { paramPicker.transition(.move(edge: .bottom).combined(with: .opacity)) }
            paramStrip
            mainControls.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .background(.black.opacity(0.75))
        .animation(.easeInOut(duration: 0.2), value: activeParam)
    }

    private var paramStrip: some View {
        HStack(spacing: 0) {
            paramCell(label: "ISO",   value: "\(Int(camera.iso))",        param: .iso)
            divider
            paramCell(label: "SS",    value: camera.shutterSpeed.display,  param: .shutter)
            divider
            paramCell(label: "FOCUS", value: String(format: "%.2f", camera.lensPosition), param: .focus)
            divider
            paramCell(label: "KROK",  value: "\(Int(stepMM)) mm",          param: .stopCondition)
        }
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle().frame(width: 1, height: 30).foregroundColor(.white.opacity(0.2))
    }

    private func paramCell(label: String, value: String, param: ActiveParam) -> some View {
        Button { withAnimation { activeParam = activeParam == param ? .none : param } } label: {
            VStack(spacing: 2) {
                Text(label).font(.system(size: 9)).foregroundColor(activeParam == param ? .yellow : .gray)
                Text(value).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundColor(.white)
            }.frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var paramPicker: some View {
        switch activeParam {
        case .iso:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach([32, 50, 100, 200, 400, 800, 1600, 3200], id: \.self) { v in
                        chip("\(v)", Int(camera.iso) == v) { camera.applyISO(Float(v)) }
                    }
                }.padding(.horizontal, 14)
            }.frame(height: 44).background(Color.black.opacity(0.6))

        case .shutter:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ShutterSpeed.presets) { ss in
                        chip(ss.display, camera.shutterSpeed.display == ss.display) { camera.applyShutter(ss) }
                    }
                }.padding(.horizontal, 14)
            }.frame(height: 44).background(Color.black.opacity(0.6))

        case .stopCondition:
            VStack(spacing: 4) {
                HStack {
                    Text("Krok: \(Int(stepMM)) mm").font(.caption).foregroundColor(.white)
                    Spacer()
                    Button("Zavřít") { withAnimation { activeParam = .none } }.font(.caption2).buttonStyle(.bordered)
                }.padding(.horizontal, 14)
                Slider(value: $stepMM, in: 10...200, step: 5).padding(.horizontal, 14)
            }.padding(.vertical, 8).background(Color.black.opacity(0.6))

        case .focus:
            VStack(spacing: 4) {
                Text("Ťukni na scénu → zaostří").font(.caption2).foregroundColor(.yellow)
                HStack {
                    Text("Pozice: \(String(format: "%.2f", camera.lensPosition))").font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                    Spacer()
                    Button("Zavřít") { withAnimation { activeParam = .none } }.font(.caption2).buttonStyle(.bordered)
                }.padding(.horizontal, 14)
            }.padding(.vertical, 8).background(Color.black.opacity(0.6))

        default: EmptyView()
        }
    }

    // MARK: - Hlavní ovládací lišta

    private var mainControls: some View {
        HStack(spacing: 12) {
            // Zamknout
            Button { camera.isLocked ? camera.unlockAll() : camera.lockAll() } label: {
                VStack(spacing: 2) {
                    Image(systemName: camera.isLocked ? "lock.open.fill" : "lock.fill")
                        .font(.title2).foregroundColor(camera.isLocked ? .orange : .green)
                    Text(camera.isLocked ? "Odemknout" : "Zamknout").font(.system(size: 9)).foregroundColor(.gray)
                }.frame(width: 60)
            }

            // Start / Stop
            Button { handleMainButton() } label: {
                ZStack {
                    Circle().fill(mainBtnColor).frame(width: 70, height: 70)
                    if case .scanning = session.state {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white).frame(width: 24, height: 24)
                    } else {
                        Circle().fill(Color.white).frame(width: 60, height: 60)
                    }
                }
            }

            // Přerušit sken (vždy viditelné pokud je aktivní sken)
            if currentScan != nil {
                Button { showAbortConfirm = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2).foregroundColor(.red)
                        Text("Ukončit").font(.system(size: 9)).foregroundColor(.red)
                    }.frame(width: 60)
                }
            } else {
                // Hlas ON/OFF
                Button { voice.isListening ? voice.stopListening() : voice.startListening() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: voice.isListening ? "waveform.circle.fill" : "waveform.circle")
                            .font(.title2).foregroundColor(voice.isListening ? .green : .gray)
                        Text(voice.isListening ? "Hlas ON" : "Hlas OFF").font(.system(size: 9)).foregroundColor(voice.isListening ? .green : .gray)
                    }.frame(width: 60)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Stitch overlay

    private var stitchOverlay: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Skládám \(currentPhase.displayName)…").font(.headline).foregroundColor(.white)
                ProgressView(value: stitchProgress).progressViewStyle(.linear).frame(width: 260)
                Text(stitchMsg).font(.caption).foregroundColor(.gray)
                Text("\(Int(stitchProgress * 100)) %").font(.title3.bold()).foregroundColor(.white)
            }
            .padding(28).background(.ultraThinMaterial).cornerRadius(18)
        }
    }

    // MARK: - Stitch náhled (po každé fázi)

    private var stitchPreviewSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Zoomovatelný náhled
                if let img = stitchPreview {
                    ZoomableImageView(image: img)
                }

                // Info + akce
                VStack(spacing: 12) {
                    HStack {
                        Circle().fill(currentPhase.color).frame(width: 10, height: 10)
                        Text(currentPhase.displayName).font(.title3.bold()).foregroundColor(currentPhase.color)
                        Spacer()
                        Text("Přiblíž prsty pro detail").font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.top, 12)

                    HStack(spacing: 12) {
                        Button("Opakovat sken") {
                            showStitchPreview = false
                            repeatCurrentPhase()
                        }
                        .buttonStyle(.bordered)

                        Button(nextPhaseLabel) {
                            showStitchPreview = false
                            advanceToNextPhase()
                        }
                        .buttonStyle(.borderedProminent).tint(currentPhase.color)
                    }

                    // Ukončit sken – vždy dostupné
                    Button("Ukončit skenování desky") {
                        showStitchPreview = false
                        showAbortConfirm = true
                    }
                    .font(.caption).foregroundColor(.red)
                    .padding(.bottom, 20)
                }
                .background(.ultraThinMaterial)
            }
            .ignoresSafeArea(edges: .top)
            .navigationTitle("Náhled – \(currentPhase.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let img = stitchPreview {
                        ShareLink(item: Image(uiImage: img),
                                  preview: SharePreview(currentPhase.displayName,
                                                        image: Image(uiImage: img))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private var nextPhaseLabel: String {
        if let next = currentPhase.next { return "Další: \(next.displayName) →" }
        return "Hotovo – zobrazit desku"
    }

    // MARK: - Logika

    private func handleMainButton() {
        switch session.state {
        case .tracking:
            if currentScan == nil { boardName = ""; showNameInput = true }
            else { startCurrentPhase() }
        case .scanning: stopAndStitch()
        default: break
        }
    }

    private func startNewBoard() {
        let name = boardName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let scan = BoardScan.create(name: name)
        store.add(scan)
        currentScan = scan
        currentPhase = .faceA
        startCurrentPhase()
    }

    private func startCurrentPhase() {
        guard let scan = currentScan else { return }
        session.stepMM = Float(stepMM)
        session.captureMode = .spatial
        session.stopCondition = .manual
        session.overrideOutputFolder = scan.phaseFolder(currentPhase)
        session.startScan()
    }

    private func stopAndStitch() {
        session.stopScan()
        guard let scan = currentScan else { return }
        let folder = scan.phaseFolder(currentPhase)
        let phase  = currentPhase
        stitching = true; stitchProgress = 0; stitchMsg = "Spouštím…"

        let engine = StitchingEngine()
        engine.pxPerMM = 10.0
        engine.progressHandler = { p, msg in
            DispatchQueue.main.async { self.stitchProgress = p; self.stitchMsg = msg }
        }
        Task {
            do {
                let result = try await engine.stitch(scanFolder: folder)
                var updated = scan
                updated.phases[phase.rawValue].isComplete = true
                updated.phases[phase.rawValue].frameCount = session.capturedFrameCount
                updated.phases[phase.rawValue].hasStitch  = true
                store.update(updated); currentScan = updated
                DispatchQueue.main.async {
                    self.stitching = false
                    self.stitchPreview = result.image
                    self.showStitchPreview = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.stitching = false
                    self.showStitchPreview = true
                }
            }
        }
    }

    private func repeatCurrentPhase() {
        if let scan = currentScan {
            let folder = scan.phaseFolder(currentPhase)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        startCurrentPhase()
    }

    private func advanceToNextPhase() {
        if let next = currentPhase.next {
            currentPhase = next
            // Zobrazit info o přechodu B/D (snižit stojany)
            startCurrentPhase()
        } else {
            if let scan = currentScan { store.update(scan) }
            showUnfolded = true
            // Reset pro příští desku
            currentScan = nil
        }
    }

    private func abortScan(save: Bool) {
        if case .scanning = session.state { session.stopScan() }
        if !save, let scan = currentScan { store.delete(scan) }
        currentScan = nil
        showList = save  // po uložení rovnou zobrazit seznam
    }

    // MARK: - Voice

    private func handleVoice(_ cmd: VoiceCommand) {
        switch cmd {
        case .start:
            if case .tracking = session.state { handleMainButton() }
        case .stop:
            if case .scanning = session.state { stopAndStitch() }
        case .lock:   camera.lockAll()
        case .unlock: camera.unlockAll()
        case .unknown: break
        }
    }

    // MARK: - Helpers

    private var mainBtnColor: Color {
        switch session.state {
        case .scanning: return .red.opacity(0.8)
        case .tracking: return currentScan == nil ? .blue.opacity(0.8) : currentPhase.color.opacity(0.8)
        default: return .gray.opacity(0.5)
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

    private func chip(_ label: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
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
