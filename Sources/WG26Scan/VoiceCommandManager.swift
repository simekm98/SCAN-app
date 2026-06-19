import Foundation
import Speech
import AVFoundation

final class VoiceCommandManager: NSObject, ObservableObject {

    @Published var isListening: Bool = false
    @Published var lastRecognized: String = ""
    @Published var permissionGranted: Bool = false

    var onCommand: ((VoiceCommand) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var restartTimer: Timer?

    private let commandMap: [String: VoiceCommand] = [
        "start": .start, "spustit": .start, "skenuj": .start,
        "stop": .stop, "zastavit": .stop, "zastav": .stop, "konec": .stop,
        "zamknout": .lock, "zamkni": .lock, "lock": .lock,
        "odemknout": .unlock, "odemkni": .unlock, "unlock": .unlock,
    ]

    override init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "cs-CZ"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.permissionGranted = (status == .authorized)
            }
        }
    }

    func startListening() {
        guard permissionGranted, !isListening else { return }
        do {
            try startRecognitionSession()
            DispatchQueue.main.async { self.isListening = true }
        } catch {
            print("Voice start error: \(error)")
        }
    }

    func stopListening() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        restartTimer?.invalidate()
        DispatchQueue.main.async { self.isListening = false }
    }

    private func startRecognitionSession() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                DispatchQueue.main.async { self.lastRecognized = text }
                self.detectCommand(in: text)
            }
            if error != nil || result?.isFinal == true {
                self.restartAfterDelay()
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: false) { [weak self] _ in
            self?.restartAfterDelay()
        }
    }

    private func detectCommand(in text: String) {
        for (keyword, command) in commandMap {
            if text.contains(keyword) {
                DispatchQueue.main.async { self.onCommand?(command) }
                return
            }
        }
    }

    private func restartAfterDelay() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
        restartTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            try? self.startRecognitionSession()
        }
    }
}
