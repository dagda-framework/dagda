#!/usr/bin/env python3
"""Verify hit-test through a real dagda-client at two viewport
sizes: the same canvas point hits the same element a pointer
would, in logical window coordinates as reported by inspect."""
import json, os, select, sys, shutil, subprocess, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"

def cleanup(proc, grace=2):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=grace)
    else:
        proc.wait(timeout=grace)


class StartupFailure(AssertionError):
    def __init__(self, message, proc):
        super().__init__(message)
        self.proc = proc


def launch(argv, timeout=10, expected=None):
    # Cleanup is established immediately after Popen, so a
    # stalled or partial readiness line never leaks the child.
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=ROOT)
    try:
        fd, buf, deadline = proc.stdout.fileno(), b"", time.monotonic() + timeout
        while b"\n" not in buf:
            left = deadline - time.monotonic()
            if left <= 0: raise AssertionError("startup timeout")
            ready, _, _ = select.select([fd], [], [], left)
            if not ready: raise AssertionError("startup timeout")
            chunk = os.read(fd, 4096)
            if not chunk: raise AssertionError("host closed stdout")
            buf += chunk
        line = buf.decode().strip()
        if expected is not None and line != expected:
            raise AssertionError(f"unexpected startup line: {line!r}")
        return proc, line
    except BaseException as e:
        cleanup(proc)
        raise StartupFailure(str(e), proc) from e


def start(host, sock, w, h):
    sock_dir = sock.parent; sock_dir.mkdir(exist_ok=True); os.chmod(sock_dir, 0o700)
    proc, _line = launch([str(host), str(sock), str(w), str(h)], expected=f"Listening {sock}")
    return proc


def raw_hit(sock, request):
    import socket as socket_mod
    with socket_mod.socket(socket_mod.AF_UNIX, socket_mod.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(str(sock))
        s.sendall(request.encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = s.recv(4096)
            if not chunk: break
            data += chunk
    return json.loads(data)

def client(client_bin, sock, *args, expect_ok=True):
    r = subprocess.run([str(client_bin), str(sock), *args], capture_output=True, text=True, timeout=15)
    if expect_ok: assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r.returncode, (json.loads(r.stdout) if r.stdout.strip() else {})

def inspect(client_bin, sock, role):
    _, resp = client(client_bin, sock, "inspect", role)
    return resp["elements"][0]

def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-hit-test-"))
    try:
        # Partial readiness line + SIGTERM ignored: launch must
        # time out on a short budget and still reap the child.
        fake_src = "import signal,time,sys; signal.signal(signal.SIGTERM, signal.SIG_IGN); sys.stdout.write('Listening partial'); sys.stdout.flush(); time.sleep(30)"
        try:
            launch([sys.executable, "-c", fake_src], timeout=1)
            raise AssertionError("partial-line child should have timed out")
        except StartupFailure as e:
            assert "timeout" in str(e), e
            assert e.proc.poll() is not None, "partial-line child was not reaped"
        wrong_src = "import time,sys; sys.stdout.write('wrong\\n'); sys.stdout.flush(); time.sleep(30)"
        try:
            launch([sys.executable, "-c", wrong_src], timeout=5, expected="Listening /x")
            raise AssertionError("wrong-line child should have failed validation")
        except StartupFailure as e:
            assert "unexpected startup line" in str(e), e
            assert e.proc.poll() is not None, "wrong-line child was not reaped"
        # (launch already terminated, escalated, and reaped it;
        # reaching here without a leaked child is the assertion)
        host, client_bin = tmp / "hit-host", tmp / "dagda-client"
        for src, out in [("dagda/driver/tests/hit_host", host), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        for width, height in [(1200, 540), (720, 540)]:
            sock = tmp / f"sock-{width}" / "app.sock"
            proc = start(host, sock, width, height)
            try:
                over = inspect(client_bin, sock, "over")["bounds"]
                under_b = inspect(client_bin, sock, "under")["bounds"]
                # Midpoint of the positive-area intersection of
                # the two reported rectangles: strictly inside
                # both, not on either exclusive edge.
                ix = max(over["x"], under_b["x"])
                iy = max(over["y"], under_b["y"])
                ir = min(over["x"] + over["width"], under_b["x"] + under_b["width"])
                ib = min(over["y"] + over["height"], under_b["y"] + under_b["height"])
                assert ir > ix and ib > iy, (over, under_b)
                centre = ((ix + ir) / 2, (iy + ib) / 2)
                _, hit = client(client_bin, sock, "hit-test", str(centre[0]), str(centre[1]))
                assert hit == {"ok": True, "id": 2}, hit  # overlap: topmost, same as a pointer
                # A point only in the under element (ID 0 is valid):
                u = inspect(client_bin, sock, "under")["bounds"]
                _, hit0 = client(client_bin, sock, "hit-test", str(u["x"] + 5), str(u["y"] + 5))
                assert hit0 == {"ok": True, "id": 0}, hit0
                _, miss = client(client_bin, sock, "hit-test", "2", "2")
                assert miss == {"ok": True, "id": None}, miss  # letterbox / outside at this size may vary; 2,2 is outside canvas sheet only at wide sizes
                # Client and raw socket agree on the huge finite
                # point (successful miss, ID 0 stays distinct),
                # on the clipped edge in/out, and on 1e40.
                huge = "18446744073709551746"
                _, via_client = client(client_bin, sock, "hit-test", huge, "150")
                via_socket = raw_hit(sock, f'{{"op":"hit-test","x":{huge},"y":150}}')
                assert via_client == via_socket == {"ok": True, "id": None}, (via_client, via_socket)
                inside = ("1079.9998779296875", "520") if width == 1200 else ("719.99993896484375", "450")
                outside = ("1080", "520") if width == 1200 else ("720", "450")
                _, c_in = client(client_bin, sock, "hit-test", *inside)
                s_in = raw_hit(sock, f'{{"op":"hit-test","x":{inside[0]},"y":{inside[1]}}}')
                assert c_in == s_in == {"ok": True, "id": 3}, (c_in, s_in)
                _, c_out = client(client_bin, sock, "hit-test", *outside)
                s_out = raw_hit(sock, f'{{"op":"hit-test","x":{outside[0]},"y":{outside[1]}}}')
                assert c_out == s_out == {"ok": True, "id": None}, (c_out, s_out)
                for sign in ("", "-"):
                    tok = sign + "340282346638528859811704183484516925440"
                    _, c_max = client(client_bin, sock, "hit-test", tok, "150")
                    s_max = raw_hit(sock, f'{{"op":"hit-test","x":{tok},"y":150}}')
                    assert c_max == s_max == {"ok": True, "id": None}, (tok, c_max, s_max)
                big_socket = raw_hit(sock, '{"op":"hit-test","x":1e40,"y":150}')
                assert big_socket == {"ok": False, "error": "Malformed_Request"}, big_socket
                big_code, _ = client(client_bin, sock, "hit-test", "1e40", "150", expect_ok=False)
                assert big_code != 0, big_code

                code, bad = client(client_bin, sock, "hit-test", "abc", "1", expect_ok=False)
                assert code == 2 or bad.get("ok") is False, (code, bad)
            finally:
                cleanup(proc)
        # Unit-scale tiny button: centre derived only from the
        # JSON reply must hit it; its exact right edge must miss.
        sock = tmp / "sock-tiny" / "app.sock"
        proc = start(host, sock, 960, 540)
        try:
            tiny = inspect(client_bin, sock, "tiny")
            assert tiny["id"] == 5, tiny
            all_els = client(client_bin, sock, "inspect")[1]["elements"]
            unfiltered = [e for e in all_els if e["id"] == 5][0]
            assert unfiltered["bounds"] == tiny["bounds"], (unfiltered, tiny)
            b = tiny["bounds"]
            cx, cy = b["x"] + b["width"] / 2, b["y"] + b["height"] / 2
            _, hit = client(client_bin, sock, "hit-test", str(cx), str(cy))
            assert hit == {"ok": True, "id": 5}, (b, hit)
            _, edge = client(client_bin, sock, "hit-test", str(b["x"] + b["width"]), str(cy))
            assert edge == {"ok": True, "id": None}, edge
            print(f"tiny bounds {b} centre ({cx}, {cy}) -> id 5; right edge -> null")
        finally:
            cleanup(proc)
        print("hit-test client checks passed at two viewport sizes")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    raise SystemExit(main())
