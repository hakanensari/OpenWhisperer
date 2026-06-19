import Foundation
import Combine
import OpenWhispererKit

/// Hosts the in-process native TTS: a `SpeechSynthesizer` actor (FluidAudio CoreML/ANE, Kokoro
/// or Supertonic3 per the `tts_engine` pref) behind a tiny embedded HTTP server
/// (`TTSHTTPServer`) on :8000. Replaces the out-of-process Python `unified_server.py`. STT is
/// native in-app and needs no server.
class ServerManager: ObservableObject {
    enum ServerStatus: String {
        case stopped = "Stopped"
        case starting = "Starting..."
        case running = "Running"
        case error = "Error"
    }

    @Published var status: ServerStatus = .stopped
    @Published var port: Int = 8000
    @Published var sttModel: String = "whisper-large-v3-turbo"  // native WhisperKit
    @Published var ttsModel: String = "Kokoro-82M"              // native FluidAudio
    @Published var lastError: String = ""

    /// Active TTS backend, selected by the `tts_engine` pref. `var` so `reloadTTSEngine()`
    /// can swap it; used for the blocking `/v1/audio/speech` path and (via `playback`) streaming.
    private var tts: any SpeechSynthesizer
    private var currentTTSEngine: TTSEngine
    /// In-process TTS playback (Phase 3). Shared with `DictationManager` (via `AppDelegate`) for
    /// instant barge-in, and with `TTSHTTPServer` to serve `/v1/audio/play`. The object is stable
    /// across engine changes (it swaps its synthesizer internally) so the injected reference stays valid.
    let playback: TTSPlaybackController
    private var httpServer: TTSHTTPServer?
    private var prepareTask: Task<Void, Never>?

    init() {
        let engine = TTSEngine.load()
        let synth = ServerManager.makeSynthesizer(engine)
        currentTTSEngine = engine
        tts = synth
        playback = TTSPlaybackController(tts: synth)
        ttsModel = engine.label
    }

    /// Build the synthesizer backend for a TTS engine.
    static func makeSynthesizer(_ engine: TTSEngine) -> any SpeechSynthesizer {
        switch engine {
        case .kokoro: return KokoroSynthesizer()
        case .supertonic3: return Supertonic3Synthesizer()
        }
    }

    /// Called from the menu when the user picks a different TTS engine. Swaps the synthesizer in
    /// the (stable) playback controller, rebuilds the HTTP server with it, and reloads the model.
    /// No-op if the saved engine is unchanged. Main thread.
    func reloadTTSEngine() {
        let chosen = TTSEngine.load()
        guard chosen != currentTTSEngine else { return }
        currentTTSEngine = chosen
        let synth = ServerManager.makeSynthesizer(chosen)
        tts = synth
        ttsModel = chosen.label
        Task { await playback.setSynthesizer(synth) }
        restartAll()
    }

    var isRunning: Bool { status == .running }
    var statusLabel: String { status.rawValue }

    /// Start the embedded server and load the TTS model. `.starting` until the model is
    /// resident, then `.running`; `.error` (with `lastError`) on bind/load failure.
    func startAll() {
        let work = { [self] in
            guard httpServer == nil else { return }
            Paths.ensureDirectories()
            status = .starting
            lastError = ""

            let server = TTSHTTPServer(port: UInt16(port), tts: tts, playback: playback)
            do {
                try server.start()
                httpServer = server
            } catch {
                status = .error
                lastError = "Failed to bind port \(port): \(error.localizedDescription)"
                NSLog("TTS server failed to start: \(error)")
                return
            }

            prepareTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.tts.prepare()
                    await MainActor.run { self.status = .running }
                } catch {
                    await MainActor.run {
                        self.status = .error
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Stop the embedded server. In-process, so there is no child process to reap — stop is
    /// immediate (the `synchronous` flag is retained for call-site compatibility).
    func stopAll(synchronous: Bool = false) {
        prepareTask?.cancel()
        prepareTask = nil
        httpServer?.stop()
        httpServer = nil
        status = .stopped
    }

    func restartAll() {
        stopAll()
        startAll()
    }
}

// MARK: - FileHandle Helper

extension FileHandle {
    static func forWritingOrCreate(at url: URL) -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
    }
}
