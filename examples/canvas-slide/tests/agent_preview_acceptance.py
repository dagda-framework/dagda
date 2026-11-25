#!/usr/bin/env python3
"""VisiDeck acceptance: an agent preview must not disturb a live
headline composition, and its stale commit must not steal the
person's finished edit.

Sequence (one headline, one revision counter, one undo history,
shared by the window keyboard path and a real dagda-client):
select "Canvas" and start a visible preedit -> record title and
revision R -> client previews "Agent draft" at R -> inspection
still reads the original at R and the composing highlight/caret
stay -> finish the composition with "é" (no click or refocus) ->
both views read "Slide é" at R+1 with one undo entry -> the
agent commit at the original R is Stale_Revision at R+1 ->
Ctrl+Z once -> exact original bytes in both views at R+2, undo
entry consumed. The composing capture taken after the agent
preview is retained under build/agent-acceptance/.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import acceptance_test as base

ROOT = base.ROOT
ODIN = base.ODIN


def client(client_bin, sock, *args, expect_ok=True):
    code, resp = base.run_client(client_bin, sock, *args)
    if expect_ok:
        assert code == 0, (args, code, resp)
    return code, resp


def headline(client_bin, sock):
    _, resp = client(client_bin, sock, "inspect", "slide.headline")
    return resp["elements"][0]


def composing_geometry(png_path, bounds):
    """(preedit highlight bbox, caret column) inside the headline."""
    w, h, rgb = base.decode_png_rgb(png_path)
    x0, y0 = max(0, int(bounds["x"])), max(0, int(bounds["y"]))
    x1, y1 = min(w, int(bounds["x"] + bounds["width"])), min(h, int(bounds["y"] + bounds["height"]))
    bg = []
    amber_cols = {}
    for y in range(y0, y1):
        for x in range(x0, x1):
            px = base.pixel_at(w, rgb, x, y)
            if base.rgb_close(px, base.PREEDIT_BG_RGB):
                bg.append((x, y))
            elif base.rgb_close(px, base.CARET_AMBER_RGB):
                amber_cols[x] = amber_cols.get(x, 0) + 1
    assert bg, f"no composing highlight in {png_path}"
    bbox = (min(q[0] for q in bg), min(q[1] for q in bg), max(q[0] for q in bg), max(q[1] for q in bg))
    # The caret is the amber column with a tall vertical run;
    # the underline is only a few rows high.
    tall = [x for x, n in amber_cols.items() if n >= 8]
    assert tall, f"no caret column in {png_path}: {amber_cols}"
    # Report field-relative positions so measurements at
    # different window scales can be compared directly.
    rel = tuple(round(v, 4) for v in (
        (bbox[0] - bounds["x"]) / bounds["width"],
        (bbox[1] - bounds["y"]) / bounds["height"],
        (bbox[2] - bounds["x"]) / bounds["width"],
        (bbox[3] - bounds["y"]) / bounds["height"],
        (max(tall) - bounds["x"]) / bounds["width"],
    ))
    return rel


def capture_current(proc, reader, client_bin, sock, png_path):
    """Screenshot paired with current headline bounds.

    Retries when a compositor resize lands between the inspect
    and the capture, so the bounds and pixels always describe
    the same frame geometry.
    """
    deadline = time.monotonic() + 3.0
    while True:
        before = headline(client_bin, sock)
        base.send_control(proc, reader, f"screenshot {png_path}")
        after = headline(client_bin, sock)
        if before["bounds"] == after["bounds"]:
            return before
        if time.monotonic() >= deadline:
            raise AssertionError(f"window kept resizing; screenshot {png_path} has no verified bounds")
        time.sleep(0.05)


def headline_ink(png_path, bounds):
    """(ink bbox, cropped headline pixels) for painted-text checks."""
    w, h, rgb = base.decode_png_rgb(png_path)
    x0, y0 = max(0, int(bounds["x"])), max(0, int(bounds["y"]))
    x1, y1 = min(w, int(bounds["x"] + bounds["width"])), min(h, int(bounds["y"] + bounds["height"]))
    ink = []
    crop = bytearray()
    for y in range(y0, y1):
        for x in range(x0, x1):
            px = base.pixel_at(w, rgb, x, y)
            is_ink = px[0] > 220 and px[1] > 220 and px[2] > 220
            crop.append(1 if is_ink else 0)  # glyph mask only: caret/focus pixels excluded
            if is_ink:
                ink.append((x, y))
    assert ink, f"no painted headline ink in {png_path}"
    bbox = (min(q[0] for q in ink), min(q[1] for q in ink), max(q[0] for q in ink), max(q[1] for q in ink))
    # Top of the final glyph only (rightmost quarter of the ink),
    # where é carries an accent and plain e does not.
    cut = bbox[0] + (bbox[2] - bbox[0]) * 3 // 4
    final_top = min(q[1] for q in ink if q[0] >= cut)
    return bbox, bytes(crop), final_top, (x1 - x0, y1 - y0)


def resample_mask(mask, dims, cols=120, rows=24):
    w, h = dims
    out = bytearray()
    for r in range(rows):
        for c in range(cols):
            out.append(mask[(r * h // rows) * w + (c * w // cols)])
    return bytes(out)


def capture_original_reference(canvas_bin, client_bin, tmp):
    """Paint the original title in a fresh 640x900 window."""
    sock_dir = tmp / "sock-reference"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "canvas.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(canvas_bin), "--size", "640x900", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, cwd=ROOT)
        reader = base.DeadlineLineReader(proc.stdout)
        assert reader.read_line("reference startup", timeout=5.0) == f"Listening {sock}"
        el = capture_current(proc, reader, client_bin, sock, tmp / "reference-original.png")
        ink, mask, _, dims = headline_ink(tmp / "reference-original.png", el["bounds"])
        base.send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        proc = None
        return ink, mask, dims, el
    finally:
        base.stop_process(proc)


def verify_single_line_regression(canvas_bin, client_bin, tmp):
    """A newline commit is rejected and the next keyboard edit works."""
    sock_dir = tmp / "sock-single-line"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "canvas.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(canvas_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, cwd=ROOT)
        reader = base.DeadlineLineReader(proc.stdout)
        assert reader.read_line("single-line startup", timeout=5.0) == f"Listening {sock}"
        capture_current(proc, reader, client_bin, sock, tmp / "single-line-init.png")
        first = headline(client_bin, sock)
        hid = first["id"]
        _, edits = client(client_bin, sock, "edits", str(hid))
        code, bad = client(client_bin, sock, "commit", str(hid), "replace_text", str(edits["revision"]), "text", "A\nB", expect_ok=False)
        assert code == 1 and bad["ok"] is False, (code, bad)
        assert headline(client_bin, sock)["text"] == "Slide Canvas"
        assert status(client_bin, sock).endswith("rev=0, undo=0"), status(client_bin, sock)
        # The next keyboard edit succeeds against the untouched state.
        hb = first["bounds"]
        base.send_control(proc, reader, f"click {hb['x'] + hb['width'] - 10.0:.2f} {hb['y'] + hb['height'] * 0.5:.2f}")
        base.send_control(proc, reader, "text Q")
        base.wait_for_role_text(client_bin, sock, "slide.headline", "Slide CanvasQ")
        base.wait_for_role_text(client_bin, sock, "slide.status", "selected=false, clicks=0, rev=1, undo=1")
        base.send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        proc = None
        print("[single-line] newline commit rejected; state untouched; next keyboard edit succeeded")
    finally:
        base.stop_process(proc)


def status(client_bin, sock):
    _, resp = client(client_bin, sock, "inspect", "slide.status")
    return resp["elements"][0]["text"]


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-agent-acceptance."))
    capture_dir = ROOT / "build" / "agent-acceptance"
    capture_dir.mkdir(parents=True, exist_ok=True)
    composing_capture = capture_dir / "composing-after-agent-preview.png"
    sock_dir = tmp / "sock"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "canvas.sock"
    proc = None
    try:
        canvas_bin, client_bin = tmp / "canvas-slide", tmp / "dagda-client"
        for src, out in [("examples/canvas-slide", canvas_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        proc = subprocess.Popen(
            [str(canvas_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, cwd=ROOT)
        reader = base.DeadlineLineReader(proc.stdout)
        assert reader.read_line("canvas startup", timeout=5.0) == f"Listening {sock}"
        capture_current(proc, reader, client_bin, sock, tmp / "init.png")

        # Discover the headline ID and revision through the client.
        first = headline(client_bin, sock)
        headline_id = first["id"]
        _, edits = client(client_bin, sock, "edits", str(headline_id))
        assert edits["edits"] == [{"name": "replace_text", "argument": "text"}], edits
        R = edits["revision"]
        assert first["text"] == "Slide Canvas" and status(client_bin, sock).endswith(f"rev={R}, undo=0")
        hb = first["bounds"]
        hy = hb["y"] + hb["height"] * 0.5
        print(f"[1] discovered headline id={headline_id} revision R={R}: 'Slide Canvas'")

        # Select "Canvas" and start a visible preedit.
        base.send_control(proc, reader, f"click {hb['x'] + hb['width'] - 10.0:.2f} {hy:.2f}")
        for _ in range(6):
            base.send_control(proc, reader, "key shift+left")
        base.send_control(proc, reader, "preedit e")
        base.wait_for_headline_composing(proc, reader, client_bin, sock, tmp / "composing-before.png",
                                         "Slide Canvas", f"selected=false, clicks=0, rev={R}, undo=0")
        paired_before = capture_current(proc, reader, client_bin, sock, tmp / "composing-before.png")
        geo_before = composing_geometry(tmp / "composing-before.png", paired_before["bounds"])
        orig_ink, orig_crop, _, _dims = headline_ink(tmp / "init.png", hb)
        print(f"[2] visible preedit over selected 'Canvas': relative highlight/caret={geo_before} ink={orig_ink}")

        # Resize the live window at preedit (800x540 -> 800x900):
        # the composition survives and field-relative highlight
        # and caret positions repeat after the resize.
        base.send_control(proc, reader, "resize 640x900")
        base.wait_for_headline_composing(proc, reader, client_bin, sock, tmp / "composing-resized.png",
                                         "Slide Canvas", f"selected=false, clicks=0, rev={R}, undo=0")
        paired_resized = capture_current(proc, reader, client_bin, sock, tmp / "composing-resized.png")
        geo_resized = composing_geometry(tmp / "composing-resized.png", paired_resized["bounds"])
        assert all(abs(a - b) <= 0.02 for a, b in zip(geo_before, geo_resized)), (geo_before, geo_resized)
        resized_size = base.decode_png_rgb(tmp / "composing-resized.png")[:2]
        init_size = base.decode_png_rgb(tmp / "init.png")[:2]
        assert resized_size != init_size, (init_size, resized_size)
        print(f"[2b] resize at preedit to 640x900: viewport {init_size} -> {resized_size}; relative geometry repeated {geo_resized}")
        geo_settled = geo_resized

        # The agent previews its replacement at R.
        _, preview = client(client_bin, sock, "preview", str(headline_id), "replace_text", str(R), "text", "Agent draft")
        assert preview["ok"] and preview["argument"] == {"kind": "text", "text": "Agent draft"}, preview
        assert headline(client_bin, sock)["text"] == "Slide Canvas"
        _, edits_after = client(client_bin, sock, "edits", str(headline_id))
        assert edits_after["revision"] == R, edits_after
        # Composing highlight and caret are still in place; retain
        # this capture after the agent preview.
        base.wait_for_headline_composing(proc, reader, client_bin, sock, composing_capture,
                                         "Slide Canvas", f"selected=false, clicks=0, rev={R}, undo=0")
        paired_after = capture_current(proc, reader, client_bin, sock, composing_capture)
        geo_after = composing_geometry(composing_capture, paired_after["bounds"])
        assert geo_after == geo_settled, f"composing highlight/caret moved across preview at settled size: {geo_settled} -> {geo_after}"
        print(f"[3] agent preview received; inspection unchanged at R={R}; composing highlight/caret identical ({composing_capture})")

        # Finish the composition with é, without clicking or
        # refocusing: the original selection survived the preview.
        base.send_control(proc, reader, "key enter")
        base.send_control(proc, reader, "text é")
        base.wait_for_role_text(client_bin, sock, "slide.headline", "Slide é")
        base.wait_for_role_text(client_bin, sock, "slide.status", f"selected=false, clicks=0, rev={R + 1}, undo=1")
        _, edits_now = client(client_bin, sock, "edits", str(headline_id))
        assert edits_now["revision"] == R + 1, edits_now
        # The window must actually paint the new headline: its
        # glyph ink is much narrower than the original's. The
        # screenshot is paired with the headline bounds current
        # at capture time, retrying across a compositor resize.
        committed_el = capture_current(proc, reader, client_bin, sock, tmp / "committed.png")
        committed_ink, committed_mask, committed_top, _ = headline_ink(tmp / "committed.png", committed_el["bounds"])
        assert committed_ink[2] - committed_ink[0] < (orig_ink[2] - orig_ink[0]) * 0.75, (orig_ink, committed_ink)
        print(f"[4] composition finished: 'Slide é' at R+1={R + 1}, one undo entry; painted ink {orig_ink} -> {committed_ink}")

        # The agent commit at the original R is now stale.
        code, stale = client(client_bin, sock, "commit", str(headline_id), "replace_text", str(R), "text", "Agent draft", expect_ok=False)
        assert code == 1 and stale == {"ok": False, "error": "Stale_Revision", "revision": R + 1}, stale
        assert headline(client_bin, sock)["text"] == "Slide é"
        print(f"[5] agent commit stale at R+1={R + 1}; person's edit preserved")

        # One Ctrl+Z in the window restores the exact original
        # bytes in both views, at R+2, consuming the undo entry.
        base.send_control(proc, reader, "key ctrl+z")
        restored = base.wait_for_role_text(client_bin, sock, "slide.headline", "Slide Canvas")
        assert restored["elements"][0]["text"].encode("utf-8") == b"Slide Canvas"
        base.wait_for_role_text(client_bin, sock, "slide.status", f"selected=false, clicks=0, rev={R + 2}, undo=0")
        # And it paints the original headline again, pixel for
        # pixel in the cropped headline region.
        undone_el = capture_current(proc, reader, client_bin, sock, tmp / "undone.png")
        undone_ink, undone_crop, _, undone_dims = headline_ink(tmp / "undone.png", undone_el["bounds"])
        ref_ink_o, ref_mask_o, ref_dims_o, ref_el_o = capture_original_reference(canvas_bin, client_bin, tmp)
        def rel_ink(ink, bounds):
            return tuple(round(v, 3) for v in ((ink[0] - bounds["x"]) / bounds["width"], (ink[1] - bounds["y"]) / bounds["height"],
                                               (ink[2] - bounds["x"]) / bounds["width"], (ink[3] - bounds["y"]) / bounds["height"]))
        mask_diff = sum(1 for a, b in zip(resample_mask(undone_crop, undone_dims), resample_mask(ref_mask_o, ref_dims_o)) if a != b) / (120 * 24)
        assert rel_ink(undone_ink, undone_el["bounds"]) == rel_ink(ref_ink_o, ref_el_o["bounds"]) and mask_diff < 0.02, (undone_ink, ref_ink_o, mask_diff)
        print(f"[6] Ctrl+Z: exact 'Slide Canvas' bytes and painted pixels in both views at R+2={R + 2}, undo consumed")

        # Glyph reference: paint ASCII "Slide e" through the same
        # app and compare. The committed é must differ from the
        # ASCII reference in the final-glyph region (its accent
        # extends the ink bbox upward), not merely in width.
        _, ref_commit = client(client_bin, sock, "commit", str(headline_id), "replace_text", str(R + 2), "text", "Slide e")
        assert ref_commit["revision"] == R + 3, ref_commit
        base.wait_for_role_text(client_bin, sock, "slide.headline", "Slide e")
        ref_el = capture_current(proc, reader, client_bin, sock, tmp / "reference-e.png")
        ref_ink, _, ref_top, _ = headline_ink(tmp / "reference-e.png", ref_el["bounds"])
        assert committed_top < ref_top, (committed_ink, committed_top, ref_ink, ref_top)
        print(f"[7] glyph reference: é final-glyph top {committed_top} above ASCII e {ref_top}; reference undone")
        base.send_control(proc, reader, "key ctrl+z")
        base.wait_for_role_text(client_bin, sock, "slide.headline", "Slide Canvas")
        base.wait_for_role_text(client_bin, sock, "slide.status", f"selected=false, clicks=0, rev={R + 4}, undo=0")

        base.send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        proc = None
        verify_single_line_regression(canvas_bin, client_bin, tmp)
        print("agent preview acceptance: all checks passed")
        return 0
    finally:
        base.stop_process(proc)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
