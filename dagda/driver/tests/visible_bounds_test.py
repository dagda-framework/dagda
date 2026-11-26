#!/usr/bin/env python3
"""Verify visible_canvas_bounds through a real dagda-client at
two window sizes: the logical-canvas intersection is identical,
only the window bounds change with the viewport."""
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"


def run_size(host, client_bin, tmp, width, height):
    sock_dir = tmp / f"sock-{width}x{height}"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "app.sock"
    proc = subprocess.Popen([str(host), str(sock), str(width), str(height)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=ROOT)
    try:
        assert proc.stdout.readline().strip() == f"Listening {sock}"
        r = subprocess.run([str(client_bin), str(sock), "inspect", "clipped"],
                           capture_output=True, text=True, timeout=15)
        assert r.returncode == 0, (r.stdout, r.stderr)
        el = json.loads(r.stdout)["elements"][0]
        assert el["visible_canvas_bounds"] == {"x": 900, "y": 480, "width": 60, "height": 60}, el
        assert el["canvas_bounds"] == {"x": 900, "y": 480, "width": 200, "height": 120}, el
        return el["bounds"]
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-visible-bounds-"))
    try:
        host, client_bin = tmp / "visible-host", tmp / "dagda-client"
        for src, out in [("dagda/driver/tests/visible_host", host), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        bounds_a = run_size(host, client_bin, tmp, 1200, 540)
        bounds_b = run_size(host, client_bin, tmp, 720, 540)
        assert bounds_a != bounds_b, (bounds_a, bounds_b)  # window bounds follow the viewport
        print(f"visible bounds identical at both sizes; window bounds {bounds_a} vs {bounds_b}")
        print("visible_canvas_bounds client checks passed")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
