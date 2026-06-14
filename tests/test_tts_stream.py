import queue
import threading
import time

import numpy as np

import tts_stream as ts


class _Res:
    def __init__(self, audio):
        self.audio = audio


def _gen(arrays):
    for a in arrays:
        yield _Res(a)


def test_pcm_bytes_roundtrip():
    a = np.array([0.0, 0.5, -0.5, 1.0], dtype=np.float32)
    b = ts.pcm_bytes(a)
    assert np.frombuffer(b, dtype="<f4").tolist() == [0.0, 0.5, -0.5, 1.0]


def test_pcm_bytes_flattens_and_casts_float64_2d():
    a = np.array([[0.1, 0.2, 0.3]], dtype=np.float64)
    out = np.frombuffer(ts.pcm_bytes(a), dtype="<f4")
    assert out.shape == (3,)
    assert np.allclose(out, [0.1, 0.2, 0.3], atol=1e-6)


def test_produce_orders_segments_then_sentinel():
    q = queue.Queue(maxsize=4)
    ev = threading.Event()
    lock = threading.Lock()
    ts.produce(_gen([np.array([0.1], np.float32), np.array([0.2], np.float32)]), q, ev, lock)
    items = []
    while True:
        x = q.get_nowait()
        if x is ts.SENTINEL:
            break
        items.append(round(float(np.frombuffer(x, dtype="<f4")[0]), 3))
    assert items == [0.1, 0.2]
    assert lock.acquire(timeout=1)   # lock released by producer
    lock.release()


def test_produce_stops_immediately_when_cancelled():
    q = queue.Queue(maxsize=1)
    ev = threading.Event()
    lock = threading.Lock()

    def inf():
        i = 0
        while True:
            yield _Res(np.array([float(i)], np.float32))
            i += 1

    ev.set()
    ts.produce(inf(), q, ev, lock)
    assert q.empty()                 # nothing produced, no sentinel
    assert lock.acquire(timeout=1)
    lock.release()


def test_produce_terminal_sentinel_put_does_not_block_forever():
    # ONE segment, queue size 1, NEVER drained: segment 0 fills the queue, then
    # generation completes and the producer reaches the terminal SENTINEL put with a
    # full queue. With cancel set, it must NOT block forever (regression: unbounded put).
    q = queue.Queue(maxsize=1)
    ev = threading.Event()
    lock = threading.Lock()
    segs = [np.array([0.0], np.float32)]
    t = threading.Thread(target=ts.produce, args=(_gen(segs), q, ev, lock), daemon=True)
    t.start()
    time.sleep(0.3)   # segment buffered (queue full); producer now at terminal SENTINEL put
    ev.set()          # cancel — must unblock the terminal put
    t.join(timeout=2)
    assert not t.is_alive()   # producer returned; no infinite block


def test_produce_backpressure_does_not_hold_lock():
    q = queue.Queue(maxsize=1)
    ev = threading.Event()
    lock = threading.Lock()
    segs = [np.array([float(i)], np.float32) for i in range(3)]
    t = threading.Thread(target=ts.produce, args=(_gen(segs), q, ev, lock), daemon=True)
    t.start()
    time.sleep(0.3)                  # producer is now blocked on a full queue
    assert lock.acquire(timeout=1)   # ...but the GPU lock MUST be free
    lock.release()
    out = []
    while True:
        x = q.get(timeout=1)
        if x is ts.SENTINEL:
            break
        out.append(round(float(np.frombuffer(x, dtype="<f4")[0]), 1))
    t.join(timeout=2)
    assert out == [0.0, 1.0, 2.0]
