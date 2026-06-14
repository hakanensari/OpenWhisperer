"""Streaming TTS helpers — deliberately free of MLX imports so they are fast to
unit-test. The producer runs model.generate() one segment at a time, holding the
GPU lock ONLY during each segment's synthesis (never during enqueue), so STT can
interleave between segments. A bounded queue gives backpressure without the lock.
"""
import logging
import queue

import numpy as np

logger = logging.getLogger("tts_stream")

TTS_SAMPLE_RATE = 24000   # Kokoro native output rate (mono)
TTS_QUEUE_MAX = 4         # bounded queue → backpressure without holding the GPU lock
SENTINEL = object()       # end-of-stream marker placed on the queue


def pcm_bytes(audio) -> bytes:
    """Convert one segment's audio (numpy array, any float dtype/shape) to
    contiguous little-endian float32 PCM bytes, mono."""
    arr = np.asarray(audio, dtype=np.float32).reshape(-1)
    return arr.astype("<f4", copy=False).tobytes()


def produce(gen, q, cancel_event, lock, *, gpu_timeout=30, put_timeout=0.2):
    """Drive `gen` (a model.generate() iterator) one segment at a time.

    For each segment: acquire `lock`, pull the next segment (synthesis happens on
    `next()`), release `lock`, then enqueue the segment's PCM bytes (blocking with
    a timeout so we stay responsive to `cancel_event` even when the queue is full).
    Terminates by putting SENTINEL — unless cancelled, in which case it returns
    without a sentinel (the drain side sets cancel_event on disconnect)."""
    try:
        while True:
            if cancel_event.is_set():
                return
            acquired = lock.acquire(timeout=gpu_timeout)
            if not acquired:
                logger.warning("TTS producer could not acquire GPU lock in %ss; proceeding unlocked", gpu_timeout)
            try:
                try:
                    result = next(gen)
                except StopIteration:
                    break
            finally:
                if acquired:
                    lock.release()
            if cancel_event.is_set():
                return
            data = pcm_bytes(result.audio)
            while True:
                try:
                    q.put(data, timeout=put_timeout)
                    break
                except queue.Full:
                    if cancel_event.is_set():
                        return
        q.put(SENTINEL)
    except Exception:
        logger.exception("TTS producer failed")
        try:
            q.put(SENTINEL, timeout=1)
        except queue.Full:
            pass
