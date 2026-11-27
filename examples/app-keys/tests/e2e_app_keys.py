"""Inspect the counter and edited text after keys pass through the SDL event loop."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "examples/composition-conflict/tests"))
from e2e_composition_conflict import DeadlineLineReader, send_control, stop_process, wait_for_role_text


def exercise(app, client, tmp):
    sock = tmp / "window.sock"
    proc = subprocess.Popen([app, "--socket", sock, "--control-stdin"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    try:
        reader = DeadlineLineReader(proc.stdout)
        assert reader.read_line("startup") == f"Listening {sock}"

        def control(command):
            return send_control(proc, reader, command)

        def inspect(role, text):
            return wait_for_role_text(client, sock, role, text)["elements"][0]

        def count(n):
            inspect("keys.count", str(n))

        count(0)
        for key, expected in [("right", 1), ("right", 2), ("left", 1), ("escape", 0), ("right", 1)]:
            control(f"key {key}")
            count(expected)

        # F10 opens the menu. Its item gains bounds while open. Escape closes
        # it, and must leave the counter at 1.
        control("key f10")
        for key in ("right", "left"):
            control(f"key {key}")
            item = inspect("keys.reset", "Reset")
            assert item["bounds"]["width"] > 0, item
            count(1)
        control("key escape")
        control("window-info")
        item = inspect("keys.reset", "Reset")
        assert item["bounds"]["width"] == 0, item
        count(1)

        field = inspect("keys.field", "abcd")["bounds"]
        control(f"click {field['x'] + 5} {field['y'] + field['height'] / 2}")
        for key in ("home", "right", "right", "right", "left", "escape"):
            control(f"key {key}")
        control("text X")
        inspect("keys.field", "abXcd")
        count(1)

        # Navigation during preedit leaves the insertion point intact. Escape
        # cancels the second preedit while an ordinary key can still insert.
        control("preedit 하")
        control("key left")
        count(1)
        control("key right")
        count(1)
        control("text 한")
        inspect("keys.field", "abX한cd")
        control("preedit 나")
        control("key escape")
        control("text !")
        inspect("keys.field", "abX한!cd")
        count(1)
        control("quit")
        assert proc.wait(timeout=5) == 0
    finally:
        stop_process(proc)


if __name__ == "__main__":
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    with tempfile.TemporaryDirectory(prefix="dagda-keys-") as directory:
        tmp = Path(directory)
        for name in ("app-keys", "dagda-client"):
            subprocess.run([ROOT / "scripts/odin.sh", "build", f"examples/{name}",
                            "-collection:dagda=.", f"-out:{tmp / name}"], cwd=ROOT, check=True)
        exercise(tmp / "app-keys", tmp / "dagda-client", tmp)
    print("Application keys, menus, caret and IME checks passed.")
