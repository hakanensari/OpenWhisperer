# TTS Streaming — Design Spec

- **Date:** 2026-06-14
- **Target release:** v1.4.0
- **Status:** Approved (brainstorming) — pending implementation plan
- **Topic:** Low-latency streaming text-to-speech (server + client)

## 1. Problem

Today's TTS path has no real streaming, so the user hears nothing until the **entire** response is synthesized end-to-end:

- [`servers/unified_server.py`](../../../servers/unified_server.py) `_serialize_tts()` (lines ~328-358) holds the global MLX GPU lock and runs the **whole** `model.generate(...)` loop, collecting **every** segment into a `chunks` list **before returning**. The `StreamingResponse` then replays an already-complete list — fake streaming.
- The client ([`hooks/tts-hook.sh`](../../../hooks/tts-hook.sh), [`hooks/codex-tts-hook.sh`](../../../hooks/codex-tts-hook.sh), [`scripts/speak.sh`](../../../scripts/speak.sh)) does `curl --output TMPFILE` (waits for the full file) then `afplay TMPFILE`. So time-to-first-audio (TTFA) = full synthesis + full download.

`model.generate()` (Kokoro) already **yields per-segment** (≈ per-sentence). The raw material to stream exists; the two halves just need connecting.

## 2. Goals / Non-goals

**Goals**
- Cut TTFA to ≈ (first-sentence synthesis + player startup) — target 60–80% reduction on multi-sentence responses.
- **Gapless** playback across sentences (radio-quality), via a continuous audio output stream.
- Preserve every existing behavior: barge-in ("hold on"), volume setting, the `tts_playing.lock` "Speaking…" state used by the Swift app, and auto-submit.
- Apply to all three entry points (Claude Code hook, Codex hook, `speak.sh`) via one shared player.
- Robust fallback to the current afplay path if streaming fails.

**Non-goals**
- No UI changes (the overlay already renders a TTS waveform from the lock file).
- No change to STT, auto-submit, or auto-focus logic.
- Not removing or changing the existing `/v1/audio/speech` (WAV) endpoint.
- No new system dependency (sounddevice + bundled PortAudio already verified in the venv).

## 3. Success criteria

1. On a 3–4 sentence response, audible speech begins after roughly the first sentence is synthesized (not the whole response).
2. Playback is continuous across sentence boundaries (no audible gaps) in the normal case (no concurrent dictation).
3. Saying "hold on" (barge-in) or a new response firing stops playback within ~100 ms and frees the GPU for STT (no wasted synthesis).
4. The `tts_volume` setting changes playback loudness, same as today.
5. If the streaming player can't start, the hook falls back to curl→WAV→afplay with no crash and no user-visible regression.
6. All three entry points behave identically.

## 4. Approach (chosen)

**Server: producer thread → bounded queue → async HTTP generator, with per-segment GPU-lock release.**

A background worker (on the existing `_tts_executor`) iterates `model.generate(...)`. For **each** segment it: acquires `_mlx_gpu_lock`, synthesizes the segment, **releases the lock**, then `put()`s the segment's raw PCM bytes onto a small **bounded** `queue.Queue` (maxsize ≈ 4). The async endpoint drains that queue and yields bytes to a chunked HTTP response.

The bounded queue provides backpressure: if the client plays slower than the server synthesizes, the producer blocks on `queue.put()` — **never while holding the GPU lock** — so STT/barge-in can acquire the GPU between segments. This is the property that prevents the deadlock the current "generate-all-under-lock" code avoids by other means.

A `threading.Event` (`cancel_event`) is checked by the producer between segments. On client disconnect (player killed for barge-in) the async generator is cancelled, which sets `cancel_event`; the producer stops generating and releases the lock immediately.

**Rejected alternatives**
- *Async generator holding the GPU lock for the whole stream, yielding per segment.* Simpler (no thread/queue) but holds the GPU lock during HTTP transfer; under real-time playback backpressure the lock is held for the full playback duration, blocking any STT that needs the GPU — re-introducing the deadlock the current design avoids. Rejected.
- *Per-segment temp WAV files + client polling/manifest.* Filesystem churn, not true streaming, clunky cleanup. Rejected.

**Client: one shared `tts_stream_player.py`** (bundled in `Resources/scripts/`, run with the venv Python). It POSTs the request, reads streamed PCM, and feeds a continuous `sounddevice.OutputStream` for gapless playback. All three entry points call this one player. (Approach for the player chosen over afplay-per-segment to get true gaplessness.)

**Wire format:** raw **float32 PCM, 24 kHz, mono** (Kokoro's native output — lossless, no encode/decode step) over a **new** endpoint, `POST /v1/audio/stream`, chunked. Response headers advertise the format: `X-Sample-Rate: 24000`, `X-Channels: 1`, `X-Sample-Format: f32le`. The player opens the output stream at 24 kHz and lets CoreAudio resample to the device rate (verified working on a 48 kHz default device).

The existing `POST /v1/audio/speech` (WAV) is kept **unchanged** for compatibility and as the fallback target.

## 5. Components

### 5.1 Server: `/v1/audio/stream` endpoint
- **Input:** the existing `SpeechRequest` body (model, input, voice, speed, etc.) — same schema as `/v1/audio/speech`.
- **Output:** chunked HTTP, `media_type=application/octet-stream` (format is conveyed via the `X-Sample-Rate`/`X-Channels`/`X-Sample-Format` headers).
- **Owns:** the producer thread handle, the bounded `queue.Queue`, and the `cancel_event`.
- **Depends on:** `model_provider`, `_mlx_gpu_lock`, `_tts_executor`.

### 5.2 Server: `_stream_tts()` producer
- For each `result` from `model.generate(...)`: acquire lock (with the existing timeout semantics) → take `result.audio` → release lock → convert to contiguous float32 little-endian bytes → `queue.put()` (blocks if full → backpressure).
- Between segments, check `cancel_event`; if set, stop the loop and return (lock released).
- On completion, enqueue a sentinel so the async drain knows to finish.
- Exceptions are logged and end the stream (the endpoint surfaces a clean error / the client falls back).

### 5.3 Client: `scripts/tts_stream_player.py`
- **Inputs:** TTS URL + JSON payload (model/input/voice…) via stdin; volume, PID-file path, lock-file path via args/env.
- **Behavior:** create `tts_playing.lock` (first action) → POST to `/v1/audio/stream` with streaming response → read fixed-size float32 frames → apply volume gain (soft-clamp) → write to `sd.OutputStream` (24 kHz, mono, float32) → on stream end, drain, remove lock + PID, exit 0.
- **Signals:** SIGTERM/SIGINT handler aborts the output stream (`stream.abort()`), removes lock + PID, exits fast (< ~100 ms target). This is the barge-in stop path.
- **Failure:** any startup error (no device, import failure, connection error) → cleanup partial lock + exit non-zero so the caller can fall back.
- **Depends on:** `sounddevice`, `numpy` (in venv), and stdlib `urllib.request` for the streaming POST (no `requests` dependency assumed).

### 5.4 Hooks + `speak.sh`
- Validate input (unchanged: jq parse, VOICE tag extraction, localhost URL guard, lock serialization).
- Build the JSON payload, then **launch the player in the background**, capturing its PID → `TTS_PIDFILE`. The player owns the lock file.
- **Fallback:** if launching the player fails or it exits non-zero immediately (self-test probe), run the existing curl→WAV→afplay path (kept intact).

### 5.5 Kill / barge-in
- Player writes its own PID to `TTS_PIDFILE`.
- Server `kill_tts()` and the hooks' prior-playback kill: SIGTERM the PID from the file (comm-check updated to accept the player process), plus `pkill -f tts_stream_player`. The existing `afplay.*tts_` patterns are **kept** for the fallback path.

## 6. Data flow

**Happy path:** hook builds JSON → launches player → player POSTs `/v1/audio/stream` → producer synthesizes sentence 1, releases lock, enqueues → HTTP streams it → player begins playback **while** the server synthesizes sentence 2 … → completion sentinel → player drains, removes lock + PID, exits 0.

**Barge-in / superseding response:** "hold on" detected (or a new hook fires) → `kill_tts`/prior-kill SIGTERMs the player → player aborts the stream and exits → the client disconnect cancels the server's async generator → `cancel_event` is set → producer stops mid-generation and releases the GPU lock → STT acquires the GPU immediately. No wasted synthesis.

## 7. Error handling & edge cases

- **Player can't start** (device/import/connect error) → non-zero exit → hook falls back to curl→WAV→afplay.
- **Client disconnect mid-stream** → server generator cancelled → `cancel_event` set → producer bails, lock released.
- **Volume** → read `tts_volume`; apply as a float gain to frames; soft-clamp to avoid clipping (`-v 1` ⇒ gain 1.0).
- **Lock-file ownership** → player creates `tts_playing.lock` on first audio, removes on exit/kill, so the Swift app's "Speaking…" state and hands-free muting are unchanged.
- **Auto-submit Enter** → unaffected (STT-side, not TTS).
- **Device sample rate ≠ 24 kHz** → player opens the stream at 24 kHz; CoreAudio resamples (verified).
- **Empty / single-sentence input** → one segment; streams and plays normally.
- **Two responses in quick succession** → the hook lock + prior-kill ensures the older player is SIGTERMed before the new one starts.

## 8. Resolved decisions

1. Endpoint name: **`/v1/audio/stream`**.
2. **Per-segment GPU-lock release: accepted.** Tradeoff: a rare micro-pause between sentences *only* when the user is actively dictating (STT competing for the GPU) during playback — in exchange for responsive barge-in.
3. **Add a minimal `pytest` setup** to the repo for the deterministic server pieces.
4. **Keep `/v1/audio/speech` (WAV)** unchanged for compatibility and fallback.
5. No further gates.

## 9. Testing strategy

- **Unit (pytest, venv):** producer segment ordering; `cancel_event` stops generation and releases the lock; queue backpressure (producer blocks without holding the lock); trigger-stripping logic unaffected. `model.generate` is mocked.
- **Player lifecycle (against a fake local PCM server):** SIGTERM latency (< ~100 ms), `tts_playing.lock` + PID created and removed, correct exit codes, fallback trigger on simulated failure.
- **Manual verification checklist:** multi-sentence input → measure TTFA vs current build; barge-in ("hold on") stops playback fast; `tts_volume` honored; fallback path works (force player failure); parity across both hooks + `speak.sh`.

## 10. Files affected (anticipated)

- `servers/unified_server.py` — add `/v1/audio/stream` + `_stream_tts()` producer + `cancel_event`; extend `kill_tts()` to target the player.
- `scripts/tts_stream_player.py` — **new** shared streaming player.
- `hooks/tts-hook.sh`, `hooks/codex-tts-hook.sh`, `scripts/speak.sh` — launch the player; keep afplay fallback; prior-kill update.
- `app/build-dmg.sh` / bundling — ensure `scripts/tts_stream_player.py` ships in `Resources/scripts/`.
- `app/Sources/OpenWhisperer/Paths.swift` — path to the bundled player script (if the Swift app needs to reference it).
- `tests/` — **new** minimal pytest setup + server-streaming unit tests.

## 11. Out of scope / future

- Word-level / sub-sentence streaming (Kokoro segments per sentence; finer granularity is a future optimization).
- STT model warmup and config-read caching (separate ROADMAP Phase 2 items).
- Cross-platform (Electron) player — tracked separately.
