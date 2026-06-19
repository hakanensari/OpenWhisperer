# Configurable STT/TTS Engines — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let the user pick the STT engine (WhisperKit · Parakeet v3 · Nemotron-multilingual) and TTS engine (Kokoro · Supertonic3) from the menubar, defaulting to Nemotron + Kokoro.

**Architecture:** A `Transcriber` protocol and a `SpeechSynthesizer` protocol, each with two/three actor conformers. Today's `SpeechTranscriber`→`WhisperKitTranscriber` and `KokoroTTS`→`KokoroSynthesizer` keep their behavior; new `FluidAudioTranscriber` and `Supertonic3Synthesizer` are added. `DictationManager`/`ServerManager` hold the active conformer behind `any Transcriber` / `any SpeechSynthesizer`, selected from a flat-file pref, rebuilt lazily on change.

**Tech Stack:** Swift 5.9+, SwiftPM (CLT only — `swift build`, no XCTest), WhisperKit 0.9+, FluidAudio 0.15.4+, AppKit/SwiftUI menubar.

## Global Constraints

- Build verification is `swift build` from `app/`; logic tests are `swift run OpenWhispererKitTests` and `swift run HookTests` (both `exit(1)` on failure). No XCTest.
- Pure, dependency-free logic goes in `OpenWhispererKit`; anything touching WhisperKit/FluidAudio/AppKit goes in `OpenWhisperer`.
- Flat-file prefs in `~/Library/Application Support/OpenWhisperer`; follow the `InteractionMode` enum pattern (`rawValue`, `label`, `save()`, `load()`-with-default).
- Offline-first: FluidAudio caches under `~/.cache/fluidaudio`; its `downloadAndLoad`/`downloadAndPreloadShared` reuse the cache. WhisperKit path unchanged.
- Conventional Commits; `Claude-Session:` trailer; no tool attribution.
- **Cannot be verified in this environment:** on-device transcription/synthesis, model downloads (firewall blocks HF Xet), GUI. Those are the user's on-device feel-test. CI gate here = compiles + logic tests pass.

## Confirmed FluidAudio call sequences (grounded in v0.15.4 source)

**Parakeet v3 (batch):**
```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)   // offline-first via modelsExist
let mgr = AsrManager(config: .default)
try await mgr.loadModels(models)
let result = try await mgr.transcribe(samples)                   // ASRResult
return result.text
```

**Nemotron multilingual (streaming, fed a finite clip):**
```swift
let shared = try await StreamingNemotronMultilingualAsrManager
    .downloadAndPreloadShared(languageCode: "auto", chunkMs: 2240)
let mgr = StreamingNemotronMultilingualAsrManager()
try await mgr.loadFromShared(shared)
// per dictation:
await mgr.setLanguage(language)          // nil/"auto" → autodetect
_ = try await mgr.process(samples: samples)
let text = try await mgr.finish()
await mgr.reset()                        // ready for next clip
return text
```

**Kokoro (unchanged):** `KokoroAneManager(variant:.english).initialize()` then `synthesizeDetailed(text:voice:)` → `(samples, sampleRate)`.

**Supertonic3:**
```swift
let manager = try await Supertonic3Manager.downloadAndCreate(/* defaults */)
let style = try await Supertonic3ResourceDownloader.loadVoiceStyle(voice: <defaultVoice>, /* … */)
let (samples, _duration) = try await manager.synthesize(text: spoken, style: style /*, … */)
return (samples, sampleRate)             // sampleRate from Supertonic3 config — confirm at impl
```

---

## Task 1: STTEngine + TTSEngine enums (pure, tested)

**Files:**
- Create: `app/Sources/OpenWhispererKit/STTEngine.swift`
- Create: `app/Sources/OpenWhispererKit/TTSEngine.swift`
- Create: `app/Tests/OpenWhispererKitTests/EngineChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (register the new check group in the runner)

**Interfaces — Produces:**
- `public enum STTEngine: String, CaseIterable, Sendable { case whisperLargeV3Turbo = "whisper-large-v3-turbo", parakeetV3 = "parakeet-v3", nemotronMultilingual = "nemotron-multilingual" }` with `public var label: String`, `public static let defaultEngine: STTEngine = .nemotronMultilingual`, `public static func parse(_ raw: String?) -> STTEngine`.
- `public enum TTSEngine: String, CaseIterable, Sendable { case kokoro = "kokoro", supertonic3 = "supertonic3" }` with `public var label: String`, `public static let defaultEngine: TTSEngine = .kokoro`, `public static func parse(_ raw: String?) -> TTSEngine`.

- [ ] **Step 1: Write `STTEngine.swift` and `TTSEngine.swift`**

```swift
// STTEngine.swift
import Foundation

/// Which speech-to-text backend drives dictation. Raw value is the pref-file string.
public enum STTEngine: String, CaseIterable, Sendable {
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"
    case parakeetV3 = "parakeet-v3"
    case nemotronMultilingual = "nemotron-multilingual"

    public var label: String {
        switch self {
        case .whisperLargeV3Turbo: return "Whisper large-v3-turbo"
        case .parakeetV3: return "Parakeet v3 (European)"
        case .nemotronMultilingual: return "Nemotron multilingual"
        }
    }

    public static let defaultEngine: STTEngine = .nemotronMultilingual

    /// Parse a pref string, falling back to the default on nil/blank/unknown.
    public static func parse(_ raw: String?) -> STTEngine {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let e = STTEngine(rawValue: raw) else { return defaultEngine }
        return e
    }
}
```

```swift
// TTSEngine.swift
import Foundation

/// Which text-to-speech backend speaks replies. Raw value is the pref-file string.
public enum TTSEngine: String, CaseIterable, Sendable {
    case kokoro = "kokoro"
    case supertonic3 = "supertonic3"

    public var label: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .supertonic3: return "Supertonic3 (multilingual)"
        }
    }

    public static let defaultEngine: TTSEngine = .kokoro

    public static func parse(_ raw: String?) -> TTSEngine {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let e = TTSEngine(rawValue: raw) else { return defaultEngine }
        return e
    }
}
```

- [ ] **Step 2: Write the failing checks** in `EngineChecks.swift` (mirrors `VoiceMigrationChecks.swift` style — a `func engineFailures() -> [String]`):

```swift
import Foundation
import OpenWhispererKit

func engineFailures() -> [String] {
    var f: [String] = []

    // round-trip
    for e in STTEngine.allCases where STTEngine(rawValue: e.rawValue) != e {
        f.append("STTEngine round-trip failed for \(e)")
    }
    for e in TTSEngine.allCases where TTSEngine(rawValue: e.rawValue) != e {
        f.append("TTSEngine round-trip failed for \(e)")
    }
    // defaults
    if STTEngine.defaultEngine != .nemotronMultilingual { f.append("STT default should be Nemotron") }
    if TTSEngine.defaultEngine != .kokoro { f.append("TTS default should be Kokoro") }
    // parse fallback
    if STTEngine.parse(nil) != .nemotronMultilingual { f.append("STT parse(nil) should default") }
    if STTEngine.parse("garbage") != .nemotronMultilingual { f.append("STT parse(unknown) should default") }
    if STTEngine.parse("  parakeet-v3 ") != .parakeetV3 { f.append("STT parse should trim + match") }
    if TTSEngine.parse("supertonic3") != .supertonic3 { f.append("TTS parse should match") }
    if TTSEngine.parse("") != .kokoro { f.append("TTS parse(blank) should default") }

    return f
}
```

- [ ] **Step 3: Register the group in the runner.** In `SubmitTriggerTests.swift` `main`, add `engineFailures()` to the aggregated failures (match the existing call style, e.g. `allFailures += engineFailures()`).

- [ ] **Step 4: Run logic tests** — Run: `cd app && swift run OpenWhispererKitTests` — Expected: exit 0, no engine failures printed.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add STTEngine/TTSEngine enums with parse + tests"`

---

## Task 2: Engine prefs + app-target load/save

**Files:**
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (add `sttEngine`, `ttsEngine` URLs)
- Create: `app/Sources/OpenWhisperer/EnginePrefs.swift` (load/save extensions referencing `Paths`)

**Interfaces — Produces:**
- `Paths.sttEngine: URL`, `Paths.ttsEngine: URL`
- `STTEngine.load() -> STTEngine`, `STTEngine.save()`, `TTSEngine.load() -> TTSEngine`, `TTSEngine.save()`

- [ ] **Step 1:** Add to `Paths.swift` after `interactionMode`:

```swift
    /// Selected STT engine (whisper-large-v3-turbo, parakeet-v3, nemotron-multilingual)
    static let sttEngine = appSupport.appendingPathComponent("stt_engine")
    /// Selected TTS engine (kokoro, supertonic3)
    static let ttsEngine = appSupport.appendingPathComponent("tts_engine")
```

- [ ] **Step 2:** Create `EnginePrefs.swift`:

```swift
import Foundation
import OpenWhispererKit

extension STTEngine {
    static func load() -> STTEngine {
        STTEngine.parse(try? String(contentsOf: Paths.sttEngine, encoding: .utf8))
    }
    func save() { try? rawValue.write(to: Paths.sttEngine, atomically: true, encoding: .utf8) }
}

extension TTSEngine {
    static func load() -> TTSEngine {
        TTSEngine.parse(try? String(contentsOf: Paths.ttsEngine, encoding: .utf8))
    }
    func save() { try? rawValue.write(to: Paths.ttsEngine, atomically: true, encoding: .utf8) }
}
```

- [ ] **Step 3:** Build — Run: `cd app && swift build` — Expected: builds clean.
- [ ] **Step 4: Commit** — `git commit -am "feat: add stt_engine/tts_engine prefs with load/save"`

---

## Task 3: Transcriber protocol + WhisperKitTranscriber

**Files:**
- Create: `app/Sources/OpenWhisperer/Transcriber.swift` (protocol)
- Rename/modify: `app/Sources/OpenWhisperer/SpeechTranscriber.swift` → keep file, rename type to `WhisperKitTranscriber`, add conformance.

**Interfaces — Produces:**
- `protocol Transcriber: Sendable { func prepare() async throws; func transcribe(samples: [Float], language: String?) async throws -> String }`
- `actor WhisperKitTranscriber: Transcriber` (today's `SpeechTranscriber`, renamed)

- [ ] **Step 1:** Create `Transcriber.swift`:

```swift
import Foundation

/// A speech-to-text backend. Conformers are actors so model load + transcribe serialize
/// on the single compute unit. `transcribe` takes 16 kHz mono normalized Float PCM.
protocol Transcriber: Sendable {
    func prepare() async throws
    func transcribe(samples: [Float], language: String?) async throws -> String
}
```

- [ ] **Step 2:** In `SpeechTranscriber.swift`, rename `actor SpeechTranscriber` → `actor WhisperKitTranscriber: Transcriber`. Change `prepare()`'s `@discardableResult func prepare() async throws -> WhisperKit` to satisfy the protocol by adding a protocol-shaped `func prepare() async throws { _ = try await loadOrReturn() }` wrapper, OR keep the returning `prepare()` and add `func prepare() async throws { _ = try await prepareWhisperKit() }`. Simplest: rename the existing returning method to `private func ensureLoaded() async throws -> WhisperKit` and add:

```swift
    func prepare() async throws { _ = try await ensureLoaded() }
```

  and have `transcribe` call `ensureLoaded()`. Keep `transcribe(samples:language:)` signature — it already matches the protocol.

- [ ] **Step 3:** Grep for other references to `SpeechTranscriber` and update them (expected: `DictationManager`, comments). Run: `cd app && grep -rn "SpeechTranscriber" Sources` — update each.
- [ ] **Step 4:** Build — Run: `cd app && swift build` — Expected: builds (DictationManager may still reference the old type name; fix in Task 5 if needed, but keep compiling by updating the stored property type to `WhisperKitTranscriber` here temporarily).
- [ ] **Step 5: Commit** — `git commit -am "refactor: SpeechTranscriber -> WhisperKitTranscriber conforming to Transcriber"`

---

## Task 4: FluidAudioTranscriber (Parakeet v3 + Nemotron)

**Files:**
- Create: `app/Sources/OpenWhisperer/FluidAudioTranscriber.swift`

**Interfaces — Consumes:** `STTEngine` (Task 1), `Transcriber` (Task 3).
**Produces:** `actor FluidAudioTranscriber: Transcriber` with `init(engine: STTEngine)` (engine must be `.parakeetV3` or `.nemotronMultilingual`).

- [ ] **Step 1:** Create `FluidAudioTranscriber.swift` using the confirmed sequences. Holds either an `AsrManager` (Parakeet) or a `StreamingNemotronMultilingualAsrManager` (Nemotron); branches on the engine. `prepare()` downloads+loads; `transcribe` runs the per-engine path (for Nemotron: `setLanguage` → `process` → `finish` → `reset`). Wrap load errors in a `loadFailed` case mirroring `WhisperKitTranscriber.TranscriberError` so the overlay copy is consistent. (Exact code written against the sequences above; confirm `AsrManager.transcribe(_:)` arity at impl — the 1-arg `transcribe(samples)` from the README.)

- [ ] **Step 2:** Build — Run: `cd app && swift build` — Expected: builds. Resolve any FluidAudio signature mismatches against the source in `.build/checkouts/FluidAudio`.
- [ ] **Step 3: Commit** — `git commit -am "feat: add FluidAudioTranscriber (Parakeet v3 + Nemotron multilingual)"`

---

## Task 5: DictationManager wiring (active transcriber from pref)

**Files:**
- Modify: `app/Sources/OpenWhisperer/DictationManager.swift`

**Interfaces — Consumes:** `STTEngine.load()` (Task 2), `Transcriber`/`WhisperKitTranscriber`/`FluidAudioTranscriber`.

- [ ] **Step 1:** Read the current `SpeechTranscriber` usage in `DictationManager` (stored property, where `transcribe`/`prepare` are called, how `stt_language` is read, how overlay status `sttStatus`/`sttModelReady` are set). Replace the concrete property with `private var transcriber: any Transcriber` built by a factory `makeTranscriber(for: STTEngine.load())` that returns `WhisperKitTranscriber()` or `FluidAudioTranscriber(engine:)`. On dictation start, if the saved engine differs from the one the current transcriber was built for, rebuild lazily (store the engine alongside). Keep passing `language:` from the existing `stt_language` read.
- [ ] **Step 2:** Build — Run: `cd app && swift build` — Expected: builds.
- [ ] **Step 3: Commit** — `git commit -am "feat: DictationManager selects STT engine from pref, rebuilds lazily"`

---

## Task 6: SpeechSynthesizer protocol + KokoroSynthesizer

**Files:**
- Create: `app/Sources/OpenWhisperer/SpeechSynthesizer.swift`
- Modify: `app/Sources/OpenWhisperer/KokoroTTS.swift` (rename type → `KokoroSynthesizer`, conform)
- Modify: `app/Sources/OpenWhisperer/TTSPlaybackController.swift` + `app/Sources/OpenWhisperer/AudioPlaybackEngine.swift` (carry the synthesizer's reported `sampleRate` instead of discarding it)

**Interfaces — Produces:**
- `protocol SpeechSynthesizer: Sendable { func prepare() async throws; func synthesizeSamples(_ text: String, voice: String) async throws -> (samples: [Float], sampleRate: Int); func synthesize(_ text: String, voice: String) async throws -> Data }`
- `actor KokoroSynthesizer: SpeechSynthesizer` (today's `KokoroTTS`)

- [ ] **Step 1:** Create `SpeechSynthesizer.swift` with the protocol above.
- [ ] **Step 2:** Rename `KokoroTTS` → `KokoroSynthesizer`, add `: SpeechSynthesizer`. Its `synthesizeSamples`/`synthesize` already match (drop the default `voice` arg from the protocol witnesses or keep — protocol requires explicit `voice:`).
- [ ] **Step 3:** In `TTSPlaybackController`, change `let (samples, _) = …` to use the returned `sampleRate` and pass it to `engine.schedule`. Verify `AudioPlaybackEngine.schedule` can accept a per-buffer sample rate; if it hardcodes 24 kHz, add a `sampleRate:` parameter and configure the player node format accordingly. (Kokoro stays 24 kHz, so behavior is unchanged; this generalization is what lets Supertonic3 play at its own rate.)
- [ ] **Step 4:** Grep + update `KokoroTTS` references (`ServerManager`, `TTSHTTPServer`). Run: `cd app && grep -rn "KokoroTTS" Sources`.
- [ ] **Step 5:** Build — Run: `cd app && swift build` — Expected: builds.
- [ ] **Step 6: Commit** — `git commit -am "refactor: KokoroTTS -> KokoroSynthesizer; thread sampleRate through playback"`

---

## Task 7: Supertonic3Synthesizer

**Files:**
- Create: `app/Sources/OpenWhisperer/Supertonic3Synthesizer.swift`

**Interfaces — Consumes:** `SpeechSynthesizer` (Task 6), `NumberNormalizer`.
**Produces:** `actor Supertonic3Synthesizer: SpeechSynthesizer`.

- [ ] **Step 1:** Read the exact Supertonic3 API at impl time: `Supertonic3Manager.downloadAndCreate(...)` params, `Supertonic3Voice` enum cases (pick a sensible default), `Supertonic3ResourceDownloader.loadVoiceStyle(...)` params, `synthesize(text:style:...)` full arg list, and the output sample rate (from `Supertonic3Config`/`Supertonic3Constants`). Files: `TTS/Supertonic3/Supertonic3Manager.swift`, `…/Supertonic3Types.swift`, `…/Assets/Supertonic3ResourceDownloader.swift`, `…/Supertonic3Constants.swift`.
- [ ] **Step 2:** Implement the actor: `prepare()` runs `downloadAndCreate` + caches the loaded `Supertonic3VoiceStyle`; `synthesizeSamples` normalizes numerics (`NumberNormalizer.normalize`) then calls `synthesize`, returning `(samples, sampleRate)`; `synthesize(_:voice:) -> Data` wraps samples in a WAV at that sample rate (reuse/extract the WAV-writer Kokoro uses, or add a small `wavData(samples:sampleRate:)` helper in `OpenWhispererKit`). The `voice` arg is ignored for v1 (single default style).
- [ ] **Step 3:** Build — Run: `cd app && swift build` — Expected: builds.
- [ ] **Step 4: Commit** — `git commit -am "feat: add Supertonic3Synthesizer"`

---

## Task 8: ServerManager / TTSHTTPServer wiring (active synthesizer from pref)

**Files:**
- Modify: `app/Sources/OpenWhisperer/ServerManager.swift`
- Modify: `app/Sources/OpenWhisperer/TTSHTTPServer.swift`
- Modify: `app/Sources/OpenWhisperer/TTSPlaybackController.swift`

**Interfaces — Consumes:** `TTSEngine.load()`, `SpeechSynthesizer`.

- [ ] **Step 1:** Change the three sites that hold `KokoroTTS`/`KokoroSynthesizer` concretely to `any SpeechSynthesizer`, built by a factory `makeSynthesizer(for: TTSEngine.load())` → `KokoroSynthesizer()` or `Supertonic3Synthesizer()`. `ServerManager.init` builds it once; `restartAll()` rebuilds from the current pref so an engine change takes effect on restart. Update `@Published var ttsModel` label from the engine.
- [ ] **Step 2:** Build — Run: `cd app && swift build` — Expected: builds.
- [ ] **Step 3: Commit** — `git commit -am "feat: ServerManager selects TTS engine from pref"`

---

## Task 9: MenuBarView pickers

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift`

- [ ] **Step 1:** Read the existing picker block (the `OWMenuPicker` usages near lines 320–630 and the `Self.languages`/`Self.voices` static option arrays + `@State`/binding pattern). Add `Self.sttEngines` and `Self.ttsEngines` option arrays from `STTEngine.allCases`/`TTSEngine.allCases` (`(id: rawValue, label: label)`), plus `@State selectedSTTEngine`/`selectedTTSEngine` bound to `STTEngine.load()`/`TTSEngine.load()`; on change call `.save()` and trigger the same restart/refresh path the platform/voice pickers use. Make the existing **voice** picker visible only when `selectedTTSEngine == .kokoro`.
- [ ] **Step 2:** Build — Run: `cd app && swift build` — Expected: builds.
- [ ] **Step 3: Commit** — `git commit -am "feat: add STT/TTS engine pickers; voice picker conditional on Kokoro"`

---

## Task 10: Verify, document, version, PR

- [ ] **Step 1:** Run logic tests — `cd app && swift run OpenWhispererKitTests` and `swift run HookTests` — Expected: both exit 0.
- [ ] **Step 2:** Release build smoke — `cd app && swift build -c release` — Expected: builds.
- [ ] **Step 3:** Bump version to `1.5.0` in `app/build-dmg.sh` and `app/Resources/Info.plist` (both together).
- [ ] **Step 4:** Update `CLAUDE.md` STT/TTS sections to note the engine pickers + new prefs (`stt_engine`, `tts_engine`) and the corrected FluidAudio model map (Parakeet=European, Nemotron=multilingual incl. Turkish).
- [ ] **Step 5:** Commit docs/version — `git commit -am "docs: document configurable engines; chore: bump 1.5.0"`
- [ ] **Step 6:** Push branch, open PR with `gh pr create`, body stating what's verified (compiles + logic tests) vs. what needs the on-device feel-test (transcription/synthesis quality, Supertonic3 sample rate, model downloads behind the firewall).

## Self-Review

- **Spec coverage:** §1 engine model→T1; §2 prefs→T2 (default via `load()` fallback, no separate seeding); §3 STT seam→T3/T4/T5 (Nemotron streaming wrinkle handled in T4); §4 TTS seam→T6/T7/T8 (single Supertonic3 voice; sampleRate threaded); §5 UI→T9 (voice picker conditional); §6 download/overlay→T4/T5 reuse `sttStatus`/`loadFailed`; §7 testing/rollout→T1/T10. Covered.
- **Placeholders:** Tasks 4/7/9 defer *exact* line-level code to impl because they require reading large existing files (`DictationManager` 932 LOC, `MenuBarView` 1423 LOC) or a few Supertonic3 lines; the call sequences and signatures are pinned above. Acceptable for inline self-execution; a fresh subagent should read the named files first.
- **Type consistency:** `Transcriber.transcribe(samples:language:)` matches `WhisperKitTranscriber`'s existing signature and is what `FluidAudioTranscriber` implements; `SpeechSynthesizer.synthesizeSamples → (samples, sampleRate)` matches `KokoroSynthesizer`'s existing return.
