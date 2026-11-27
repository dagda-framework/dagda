"""Exercise cross-paragraph IME retention and stale heading edits with a real driver."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "examples/composition-conflict/tests"))
from e2e_composition_conflict import (
    DeadlineLineReader, run_client, send_control, stop_process, wait_for_role_text,
)


def exercise(app, client, tmp):
    sock = tmp / "window.sock"
    proc = subprocess.Popen(
        [app, "--size", "640x400", "--socket", sock, "--control-stdin"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0,
    )
    try:
        reader = DeadlineLineReader(proc.stdout)
        assert reader.read_line("startup") == f"Listening {sock}"

        def control(command):
            return send_control(proc, reader, command)

        def element(role, text):
            return wait_for_role_text(client, sock, role, text)["elements"][0]

        def command(*args):
            code, result = run_client(client, sock, *map(str, args))
            assert code == 0 and result["ok"], result
            return result

        def click(bounds):
            control(f"click {bounds['x'] + 20} {bounds['y'] + 20}")

        writer = element("paragraph.writer", "Write OLD here")
        heading = element("heading", "Report")
        hid = heading["id"]
        rev = command("edits", hid)["revision"]

        # Case 1 (issue #64): unchanged state gives the same refusal at preview and commit,
        # leaving text, revision, and undo history untouched.
        p_code, p_refusal = run_client(client, sock, "preview", str(hid), "rename", str(rev), "text", "Report")
        c_code, c_refusal = run_client(client, sock, "commit", str(hid), "rename", str(rev), "text", "Report")
        assert p_code != 0 and p_refusal == {"ok": False, "error": "Not_Handled"}, (p_code, p_refusal)
        assert c_code != 0 and c_refusal == {"ok": False, "error": "Not_Handled"}, (c_code, c_refusal)
        assert command("edits", hid)["revision"] == rev
        element("heading", "Report")
        element("status", "starts=0 ends=0 heading_history=0 writer_history=0")

        click(writer["bounds"])
        control("key ctrl+a")
        control("key left")
        for _ in "Write ":
            control("key right")
        for _ in "OLD":
            control("key shift+right")
        control("preedit ㅎ")
        control("preedit 하")
        deadline = time.monotonic() + 5
        while True:
            moved = element("paragraph.writer", "Write OLD here")
            if moved["bounds"]["y"] > writer["bounds"]["y"]:
                break
            assert time.monotonic() < deadline, "worker insertion never moved paragraph B"
            time.sleep(0.01)
        assert moved["id"] == writer["id"]
        element("paragraph.inserted", "Remote paragraph")
        # Case 2: valid preview leaves text, revision, and undo history untouched; commit applies once.
        command("preview", hid, "rename", rev, "text", "Agent report")
        assert command("edits", hid)["revision"] == rev
        element("heading", "Report")
        element("status", "starts=1 ends=0 heading_history=0 writer_history=0")
        committed = command("commit", hid, "rename", rev, "text", "Agent report")
        assert committed["revision"] == rev + 1
        element("heading", "Agent report")
        element("status", "starts=1 ends=0 heading_history=1 writer_history=0")
        control("text 한")
        element("status", "starts=1 ends=1 heading_history=1 writer_history=1")
        assert element("paragraph.writer", "Write 한 here")["id"] == writer["id"]
        control("text !")
        element("paragraph.writer", "Write 한! here")
        click(element("heading", "Agent report")["bounds"])
        control("key ctrl+z")
        element("heading", "Report")
        element("paragraph.inserted", "Remote paragraph")
        element("paragraph.writer", "Write 한! here")

        # A second writer supersedes a preview. Rejecting the old proposal must
        # preserve both the accepted heading revision and its history depth.
        rev = command("edits", hid)["revision"]
        command("preview", hid, "rename", rev, "text", "Old proposal")
        control("key ctrl+a")
        control("text Human report")
        element("heading", "Human report")
        current = command("edits", hid)["revision"]
        assert current == rev + 1
        unchanged = "starts=1 ends=1 heading_history=1 writer_history=2"
        element("status", unchanged)
        code, refusal = run_client(client, sock, "commit", str(hid), "rename", str(rev), "text", "Old proposal")
        assert code != 0 and refusal == {"ok": False, "error": "Stale_Revision", "revision": current}
        element("status", unchanged)
        element("heading", "Human report")
        assert command("edits", hid)["revision"] == current

        # Commit-time Busy_Composing remains available while preview succeeds during heading composition.
        control("preedit é")
        command("preview", hid, "rename", current, "text", "While composing")
        assert command("edits", hid)["revision"] == current
        element("heading", "Human report")
        b_code, b_refusal = run_client(client, sock, "commit", str(hid), "rename", str(current), "text", "While composing")
        assert b_code != 0 and b_refusal == {"ok": False, "error": "Busy_Composing"}, (b_code, b_refusal)
        element("status", unchanged)
        element("heading", "Human report")
        control("quit")
        assert proc.wait(timeout=5) == 0
    finally:
        stop_process(proc)


if __name__ == "__main__":
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    with tempfile.TemporaryDirectory(prefix="dagda-paragraph-") as directory:
        tmp = Path(directory)
        for name in ("paragraph-interleaving", "dagda-client"):
            subprocess.run([ROOT / "scripts/odin.sh", "build", f"examples/{name}",
                            "-collection:dagda=.", f"-out:{tmp / name}"], cwd=ROOT, check=True)
        exercise(tmp / "paragraph-interleaving", tmp / "dagda-client", tmp)
    print("All paragraph-interleaving checks passed.")
