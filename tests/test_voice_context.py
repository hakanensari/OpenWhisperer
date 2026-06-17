import hashlib
import json
import subprocess
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "voice-context.sh"


def run_hook(input_obj, app_support, voice_turn_text=None, ts=None, detail=None):
    """Run voice-context.sh with HOME pointed at a temp dir; return (stdout, app_support)."""
    appdir = app_support / "Library" / "Application Support" / "OpenWhisperer"
    appdir.mkdir(parents=True, exist_ok=True)
    if voice_turn_text is not None:
        h = hashlib.sha256(voice_turn_text.strip().encode()).hexdigest()
        t = ts if ts is not None else _now(app_support)
        (appdir / "voice_turn").write_text(f"{h}\n{t}\n")
    if detail is not None:
        (appdir / "voice_detail").write_text(detail)
    proc = subprocess.run(
        [str(HOOK)], input=json.dumps(input_obj),
        capture_output=True, text=True,
        env={"HOME": str(app_support), "PATH": "/usr/bin:/bin:/usr/local/bin"},
    )
    return proc.stdout, appdir


def _now(app_support):
    return int(subprocess.run(["date", "+%s"], capture_output=True, text=True).stdout.strip())


def test_match_claims_and_marks(tmp_path):
    out, appdir = run_hook(
        {"prompt": "fix the login bug", "session_id": "abc-123"},
        tmp_path, voice_turn_text="fix the login bug",
    )
    assert (appdir / "speak_pending" / "abc-123").exists()      # session marked
    assert not (appdir / "voice_turn").exists()                 # signal claimed
    payload = json.loads(out)
    assert payload["suppressOutput"] is True
    assert payload["hookSpecificOutput"]["hookEventName"] == "UserPromptSubmit"
    assert "read aloud" in payload["hookSpecificOutput"]["additionalContext"]


def test_no_match_leaves_signal_and_is_silent(tmp_path):
    out, appdir = run_hook(
        {"prompt": "something I typed", "session_id": "abc-123"},
        tmp_path, voice_turn_text="fix the login bug",
    )
    assert out == ""                                            # no nudge
    assert not (appdir / "speak_pending" / "abc-123").exists()  # not marked
    assert (appdir / "voice_turn").exists()                     # signal preserved for the real session


def test_no_signal_is_silent(tmp_path):
    out, appdir = run_hook(
        {"prompt": "anything", "session_id": "abc-123"}, tmp_path,
    )
    assert out == ""
    assert not (appdir / "speak_pending").exists()


def test_stale_signal_rejected(tmp_path):
    out, appdir = run_hook(
        {"prompt": "fix the login bug", "session_id": "abc-123"},
        tmp_path, voice_turn_text="fix the login bug", ts=1,  # ancient
    )
    assert out == ""
    assert not (appdir / "voice_turn").exists()                 # stale signal swept


def test_session_id_sanitized_in_filename(tmp_path):
    out, appdir = run_hook(
        {"prompt": "go", "session_id": "a/b c:d"},
        tmp_path, voice_turn_text="go",
    )
    assert (appdir / "speak_pending" / "a_b_c_d").exists()


def test_terse_detail_changes_nudge(tmp_path):
    out, _ = run_hook(
        {"prompt": "go", "session_id": "s1"},
        tmp_path, voice_turn_text="go", detail="terse",
    )
    assert "one short, plain spoken sentence" in json.loads(out)["hookSpecificOutput"]["additionalContext"]
