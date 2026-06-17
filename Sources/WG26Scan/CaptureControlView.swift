import SwiftUI

struct CaptureControlView: View {
    @StateObject private var camera = CameraManager()

    @State private var iso: Double = 100
    @State private var exposureMs: Double = 8.0
    @State private var lensPosition: Double = 0.5
    @State private var frameCount: Int = 50
    @State private var intervalSeconds: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea(edges: .top)

                if camera.isCapturing {
                    Text("Snímek \(camera.capturedCount) / \(camera.targetCount)")
                        .padding(8)
                        .background(.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 12)
                }
            }
            .frame(maxHeight: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    parameterSliders

                    HStack {
                        Button(camera.isLocked ? "Zamčeno" : "Zamknout parametry") {
                            camera.lockAll(
                                iso: Float(iso),
                                durationSeconds: exposureMs / 1000.0,
                                lensPosition: Float(lensPosition)
                            )
                        }
                        .disabled(camera.isLocked)
                        .buttonStyle(.borderedProminent)

                        Button("Odemknout") {
                            camera.unlockAll()
                        }
                        .disabled(!camera.isLocked)
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    seriesControls

                    if let error = camera.lastError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                    if camera.droppedFrames > 0 {
                        Text("Zahozeno snímků (frekvence příliš vysoká): \(camera.droppedFrames)")
                            .foregroundColor(.orange)
                            .font(.footnote)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 280)
            .background(Color(.systemBackground))
        }
        .onAppear { camera.configureSession() }
        .onDisappear { camera.stopSession() }
    }

    private var parameterSliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ISO: \(Int(iso))")
            Slider(value: $iso, in: 32...3200, step: 1)
                .disabled(camera.isLocked)

            Text("Čas závěrky: \(String(format: "%.1f", exposureMs)) ms")
            Slider(value: $exposureMs, in: 1...50, step: 0.5)
                .disabled(camera.isLocked)

            Text("Pozice ohniska: \(String(format: "%.2f", lensPosition)) (0 = blízko, 1 = daleko)")
            Slider(value: $lensPosition, in: 0...1, step: 0.01)
                .disabled(camera.isLocked)
        }
    }

    private var seriesControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Počet snímků: \(frameCount)", value: $frameCount, in: 1...2000, step: 10)

            HStack {
                Text("Frekvence: \(String(format: "%.2f", 1.0 / intervalSeconds)) Hz")
                Spacer()
                Text("Interval: \(String(format: "%.0f", intervalSeconds * 1000)) ms")
            }
            Slider(value: $intervalSeconds, in: 0.1...3.0, step: 0.05)

            Button(camera.isCapturing ? "Zastavit" : "Spustit sérii") {
                if camera.isCapturing {
                    camera.stopSeriesCapture()
                } else {
                    camera.startSeriesCapture(count: frameCount, intervalSeconds: intervalSeconds)
                }
            }
            .disabled(!camera.isLocked)
            .buttonStyle(.borderedProminent)
            .tint(camera.isCapturing ? .red : .green)
        }
    }
}

#Preview {
    CaptureControlView()
}
