import numpy as np

import tts_stream_player as player


def _reader(data):
    pos = {"i": 0}

    def read_fn(n):
        chunk = data[pos["i"]:pos["i"] + n]
        pos["i"] += len(chunk)
        return chunk

    return read_fn


def test_iter_frames_basic_passthrough():
    data = np.array([0.0, 0.25, -0.25, 0.5], dtype="<f4").tobytes()
    out = np.concatenate(list(player.iter_frames(_reader(data), 1.0, 8)))
    assert np.allclose(out, [0.0, 0.25, -0.25, 0.5])


def test_iter_frames_applies_and_clips_gain():
    data = np.array([0.5, -0.5, 1.0], dtype="<f4").tobytes()
    out = np.concatenate(list(player.iter_frames(_reader(data), 4.0, 4)))
    assert out.tolist() == [1.0, -1.0, 1.0]   # 4x gain, clipped to [-1, 1]


def test_iter_frames_drops_trailing_partial_sample():
    data = np.array([0.1, 0.2], dtype="<f4").tobytes() + b"\x00\x00"  # 2 stray bytes
    out = np.concatenate(list(player.iter_frames(_reader(data), 1.0, 64)))
    assert out.shape == (2,)


import http.server
import os
import signal
import socket
import subprocess
import sys
import threading
import time

_HERE = os.path.dirname(__file__)
_PLAYER = os.path.join(_HERE, "..", "scripts", "tts_stream_player.py")


class _PCMHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("X-Sample-Rate", "24000")
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        block = np.zeros(2400, dtype="<f4").tobytes()  # 0.1s of silence
        for _ in range(20):  # ~2s, slow enough to SIGTERM mid-stream
            try:
                self.wfile.write(block)
                self.wfile.flush()
            except Exception:
                return
            time.sleep(0.1)

    def log_message(self, *a):
        pass


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _run_player(url, tmp_path):
    lock = tmp_path / "lock"
    pid = tmp_path / "pid"
    env = dict(os.environ, OW_TTS_PLAYER_SILENT="1")
    proc = subprocess.Popen(
        [sys.executable, _PLAYER, "--url", url, "--volume", "1.0",
         "--lockfile", str(lock), "--pidfile", str(pid)],
        stdin=subprocess.PIPE, env=env,
    )
    proc.stdin.write(b'{"model":"m","input":"hi","voice":"af_heart"}')
    proc.stdin.close()
    return proc, lock, pid


def test_player_sigterm_stops_fast_and_cleans_up(tmp_path):
    port = _free_port()
    srv = http.server.HTTPServer(("127.0.0.1", port), _PCMHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        proc, lock, pid = _run_player(f"http://127.0.0.1:{port}/v1/audio/stream", tmp_path)
        for _ in range(60):
            if lock.exists() and pid.exists():
                break
            time.sleep(0.05)
        assert lock.exists() and pid.exists()
        t0 = time.time()
        proc.send_signal(signal.SIGTERM)
        rc = proc.wait(timeout=3)
        assert time.time() - t0 < 1.0
        assert rc == 0
        assert not lock.exists() and not pid.exists()
    finally:
        srv.shutdown()


def test_player_connect_failure_exits_2_and_cleans_up(tmp_path):
    proc, lock, pid = _run_player("http://127.0.0.1:1/v1/audio/stream", tmp_path)
    rc = proc.wait(timeout=5)
    assert rc == 2
    assert not lock.exists() and not pid.exists()
