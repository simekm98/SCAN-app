import SwiftUI
import AVFoundation

/// UIView, která hostuje AVCaptureVideoPreviewLayer a udržuje jeho rozměry synchronizované.
final class PreviewHostView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(previewLayer)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(previewLayer)
        previewLayer.videoGravity = .resizeAspectFill
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

/// SwiftUI obal pro živý náhled z AVCaptureSession.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        // Session se nemění po vytvoření, není potřeba nic aktualizovat.
    }
}
