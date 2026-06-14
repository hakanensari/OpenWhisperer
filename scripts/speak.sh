#!/bin/bash
# Speaks text via local mlx_audio TTS server
# Usage: echo "text" | ./speak.sh  OR  ./speak.sh "text to speak"

TTS_URL="${TTS_URL:-http://localhost:8000/v1/audio/speech}"
VOICE="${TTS_VOICE:-af_heart}"
MODEL="${TTS_MODEL:-prince-canuma/Kokoro-82M}"
TMPFILE=$(mktemp /tmp/tts_XXXXXX.wav)

if [ -n "$1" ]; then
  TEXT="$*"
else
  TEXT=$(cat)
fi

[ -z "$TEXT" ] && exit 0

# Truncate very long text to avoid timeout
TEXT="${TEXT:0:2000}"

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VENV_PY="$APP_SUPPORT/venv/bin/python"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYER="$SCRIPT_DIR/tts_stream_player.py"
STREAM_URL="${TTS_URL%/audio/speech}/audio/stream"

if [ -x "$VENV_PY" ] && [ -f "$PLAYER" ] && "$VENV_PY" -c "import sounddevice, numpy" >/dev/null 2>&1; then
  # Streaming path (foreground — speak.sh is a synchronous CLI util)
  rm -f "$TMPFILE"  # unused on this path
  PAYLOAD="$(jq -n --arg t "$TEXT" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')"
  printf '%s' "$PAYLOAD" | "$VENV_PY" "$PLAYER" \
    --url "$STREAM_URL" --volume "${TTS_VOLUME:-1}" \
    --lockfile "$APP_SUPPORT/tts_playing.lock" --pidfile "$APP_SUPPORT/tts_hook.pid"
else
  # Fallback: curl + afplay
  curl -s -X POST "$TTS_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$TEXT" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')" \
    --output "$TMPFILE" 2>/dev/null
  afplay "$TMPFILE" 2>/dev/null
  rm -f "$TMPFILE"
fi
