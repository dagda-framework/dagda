#!/usr/bin/env python3
"""Native macOS IME desktop probe for composition-conflict.

This probe is operator-driven by design. The hosted CI session
cannot select a composing input source or deliver native IME
input, so cases that need a person at a real Mac keyboard are
recorded as pending until this probe is run on a desktop.

It launches examples/composition-conflict with ONLY --socket
(no --control-stdin, so the host keeps its native IME
subscription), keeps keyboard focus in the title window, and
issues dagda-client inspect/preview/commit requests from a
separate process while the operator composes. The fixture
records on_composition and on_commit callbacks (in order,
with host-thread ids and exact text bytes as hex) to the file
named by COMPOSITION_OBS_LOG.

Run it on an Apple Silicon Mac from the Dagda checkout, e.g.:

  python3 examples/composition-conflict/tests/macos_native_ime_probe.py \
      --input-source "Japanese - Romaji" \
      --keys "Cmd+A; type kana syllables, updating the preedit at least twice; Return accepts; Escape cancels; Cmd+Z undoes"

Before launch it asks nothing and changes no OS settings:
input-source selection and Accessibility permissions stay
under the operator's control. After launch, do not click or
type in this terminal; read the cues (printed in the terminal
and appended to transcript.txt) and type only in the Dagda
window, which must stay focused. Arrange the terminal beside
the Dagda window before running the probe.

Exit status: 0 = every case observed, 3 = at least one case
left pending (the transcript names the exact failing stage).
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_composition_conflict as base

ROOT = base.ROOT
ODIN = base.ODIN
ORIGINAL = "Alpha Title"
A_CANVAS_ID, A_OUTLINE_ID = 1, 0


class Pending(AssertionError):
    pass


def parse_obs(path):
    entries = []
    if not path.exists():
        return entries
    for line in path.read_text(encoding="utf-8").splitlines():
        entry = {}
        for token in line.split():
            if "=" in token:
                k, v = token.split("=", 1)
                entry[k] = v
        if entry:
            entries.append(entry)
    return entries


def hex_text(value):
    return bytes.fromhex(value).decode("utf-8")


class Probe:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.output_dir) if args.output_dir else Path(tempfile.mkdtemp(prefix="dagda-native-ime."))
        self.out.mkdir(parents=True, exist_ok=True)
        self.transcript = self.out / "transcript.txt"
        self.obs_log = self.out / "composition-obs.log"
        self.proc = None
        self.reader = None
        self.sock = None
        self.client_bin = None

    def record(self, message):
        print(message, flush=True)
        with self.transcript.open("a", encoding="utf-8") as fh:
            fh.write(message + "\n")

    def client(self, *cli_args):
        code, resp = base.run_client(self.client_bin, self.sock, *cli_args)
        self.record(f"client {' '.join(cli_args)} -> exit={code} {json.dumps(resp, ensure_ascii=False)}")
        return code, resp

    def inspect(self, role):
        _, resp = base.run_client(self.client_bin, self.sock, "inspect", role)
        return resp["elements"][0]

    def status(self):
        text = self.inspect("conflict.status")["text"]
        m = re.match(r"a_rev=(\d+), a_undo=(\d+), b_rev=(\d+), b_undo=(\d+)", text)
        assert m, text
        return {"a_rev": int(m.group(1)), "a_undo": int(m.group(2)),
                "b_rev": int(m.group(3)), "b_undo": int(m.group(4))}

    def obs(self):
        return parse_obs(self.obs_log)

    def wait_until(self, stage, fn, timeout):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                value = fn()
            except Exception as exc:  # keep polling; record last
                value, last = None, exc
            if value:
                return value
            time.sleep(0.1)
        raise Pending(f"stage timed out after {timeout:.0f}s: {stage}; last={last!r}")

    def check_threads(self, entries):
        for e in entries:
            assert e.get("tid") == e.get("main_tid"), f"callback off host thread: {e}"

    def environment(self):
        self.record(f"platform: system={platform.system()} machine={platform.machine()} release={platform.release()}")
        if platform.system() == "Darwin":
            for cmd in (["sw_vers"], ["defaults", "read", "com.apple.HIToolbox", "AppleSelectedInputSources"]):
                try:
                    out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                    self.record(f"{' '.join(cmd)} -> exit={out.returncode} {(out.stdout or out.stderr).strip()[:400]!r}")
                except Exception as exc:
                    self.record(f"{' '.join(cmd)} failed: {exc!r}")
        self.record(f"input source (operator-supplied): {self.args.input_source}")
        self.record(f"keys (operator-supplied): {self.args.keys}")
        self.record(f"input method: native macOS IME via SDL text input (no --control-stdin), separate dagda-client over a private socket")
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise Pending(
                f"native composition needs an Apple Silicon Mac desktop; this host is "
                f"{platform.system()}/{platform.machine()}, so no composing source can be selected or driven here"
            )

    def launch(self, tmp):
        app_bin, self.client_bin = tmp / "composition-conflict", tmp / "dagda-client"
        for src, out in [("examples/composition-conflict", app_bin), ("examples/dagda-client", self.client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
            self.record(f"built {src} -> {out}")
        sock_dir = tmp / "sock"
        sock_dir.mkdir()
        os.chmod(sock_dir, 0o700)
        self.sock = sock_dir / "app.sock"
        env = {**os.environ, "COMPOSITION_OBS_LOG": str(self.obs_log)}
        # Normal --socket launch only: no --control-stdin and no
        # dummy video driver, so SDL subscribes to the native IME.
        self.proc = subprocess.Popen([str(app_bin), "--socket", str(self.sock)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     bufsize=0, env=env, cwd=ROOT)
        try:
            self.reader = base.DeadlineLineReader(self.proc.stdout)
            line = self.reader.read_line("startup", timeout=15.0)
            assert line == f"Listening {self.sock}", line
        except BaseException:
            base.stop_process(self.proc)
            self.proc = None
            raise
        self.record(f"host listening on {self.sock} (native IME subscription enabled)")

    def run(self):
        tmp = Path(tempfile.mkdtemp(prefix="dagda-native-ime-bin."))
        try:
            self.environment()
            self.launch(tmp)
            start = self.inspect("a.canvas")
            st0 = self.status()
            assert start["text"] == ORIGINAL and st0["a_rev"] == 1 and st0["a_undo"] == 0, (start, st0)
            self.record(f"start: committed={start['text']!r} bytes={start['text'].encode('utf-8')!r} rev={st0['a_rev']} undo={st0['a_undo']}")

            # 1. Compose in A canvas; preview through A's outline view.
            self.record("CUE 1: Click the A canvas headline (upper-right field, 'Alpha Title'), "
                        "press Command+A, switch to your composing input source if needed, and start a preedit. "
                        "Do not accept the candidate yet.")
            entries = self.wait_until("composition start #1",
                                      lambda: [e for e in self.obs() if e.get("kind") == "composition_start"],
                                      self.args.stage_timeout)
            first = entries[0]
            assert first.get("field") == str(A_CANVAS_ID), first
            assert first.get("a_rev") == "1", first
            self.check_threads(self.obs())
            self.record(f"observed composition start #1: {first}")
            self.record(f"CUE 1b: Keep the preedit alive and update the marked text at least twice "
                        f"in the next {self.args.update_seconds:.0f} seconds. Do not accept yet; "
                        f"the preview below runs automatically while you compose.")
            time.sleep(self.args.update_seconds)
            before = self.obs()
            assert len([e for e in before if e.get("kind") == "composition_end"]) == 0, before
            code, preview = self.client("preview", str(A_OUTLINE_ID), "rename", "1", "text", "Agent draft")
            assert code == 0 and preview.get("ok") is True, preview
            self.record("operator: visually confirm focus, marked text and caret are still in the A canvas field (probe cannot see the preedit without the operator)")
            for role in ("a.canvas", "a.outline"):
                el = self.inspect(role)
                assert el["text"] == ORIGINAL, (role, el)
            st = self.status()
            assert st["a_rev"] == 1 and st["a_undo"] == 0, st
            after_preview = self.obs()
            assert len([e for e in after_preview if e.get("kind") == "composition_end"]) == 0, after_preview
            self.record("step 1 passed: preview succeeded during preedit; committed bytes, revision and undo depth survived")

            # 2. Accept the candidate; stale driver commit must fail.
            self.record(f"CUE 2: Accept the candidate through the input source now (for example {self.args.accept_key}). Type nothing else.")
            def committed():
                es = self.obs()
                commits = [e for e in es if e.get("kind") == "commit" and e.get("accepted") == "true"]
                ends = [e for e in es if e.get("kind") == "composition_end"]
                return (commits, ends) if commits and ends else None
            commits, ends = self.wait_until("composition commit + end #1", committed, self.args.stage_timeout)
            assert len(commits) == 1 and len(ends) == 1, (commits, ends)
            supplied = hex_text(commits[0]["text_hex"])
            seqs = [int(e["seq"]) for e in self.obs()]
            assert int(commits[0]["seq"]) < int(ends[0]["seq"]), "composition end must follow the commit callback"
            self.check_threads(self.obs())
            self.record(f"observed accepted commit: text={supplied!r} bytes={supplied.encode('utf-8')!r} entry={commits[0]}; end entry={ends[0]}")
            for role in ("a.canvas", "a.outline"):
                el = self.inspect(role)
                assert el["text"] == supplied, (role, el, supplied)
            st = self.status()
            assert st["a_rev"] == 2 and st["a_undo"] == 1, st
            code, stale = self.client("commit", str(A_OUTLINE_ID), "rename", "1", "text", "Agent draft")
            assert code != 0 and stale.get("error") == "Stale_Revision" and stale.get("revision") == 2, stale
            self.record("step 2 passed: both views show the supplied text at rev=2 with one undo entry; driver commit at rev=1 is Stale_Revision(2)")

            # 3. Cancel a second composition; one Command+Z undoes.
            self.record("CUE 3: In the still-focused A canvas field, press Command+A, start a second preedit, then cancel it (Escape).")
            def cancelled():
                es = self.obs()
                starts = [e for e in es if e.get("kind") == "composition_start"]
                ends2 = [e for e in es if e.get("kind") == "composition_end"]
                return (starts, ends2) if len(starts) >= 2 and len(ends2) >= 2 else None
            starts, ends2 = self.wait_until("composition start/end #2 (cancel)", cancelled, self.args.stage_timeout)
            assert len([e for e in self.obs() if e.get("kind") == "commit"]) == 1, self.obs()
            for role in ("a.canvas", "a.outline"):
                assert self.inspect(role)["text"] == supplied, role
            st = self.status()
            assert st["a_rev"] == 2 and st["a_undo"] == 1, st
            self.record(f"observed cancel pair: start={starts[1]} end={ends2[1]}; committed state unchanged")
            self.record("CUE 4: Press Command+Z once in the A canvas field.")
            def undone():
                el = self.inspect("a.canvas")
                st2 = self.status()
                return (el, st2) if el["text"] == ORIGINAL and st2["a_rev"] == 3 and st2["a_undo"] == 0 else None
            el, st = self.wait_until("Command+Z undo to original", undone, self.args.stage_timeout)
            assert self.inspect("a.outline")["text"] == ORIGINAL
            self.record(f"step 3 passed: cancel kept state; Command+Z restored {ORIGINAL!r} bytes={ORIGINAL.encode('utf-8')!r} at rev={st['a_rev']} undo={st['a_undo']}")

            self.record("CUE 5: Close the Dagda window now.")
            rc = self.proc.wait(timeout=self.args.stage_timeout)
            assert rc == 0, f"host exited with status {rc} after window close"
            self.proc = None
            self.record("all native IME cases observed")
            return 0
        finally:
            base.stop_process(self.proc)
            self.proc = None
            shutil.rmtree(tmp, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-source", required=True, help='e.g. "Japanese - Romaji" or "Pinyin - Simplified"')
    parser.add_argument("--keys", default="Command+A; romaji/pinyin syllables updating the preedit at least twice; Return accepts; Escape cancels; Command+Z undoes")
    parser.add_argument("--accept-key", default="Return")
    parser.add_argument("--stage-timeout", type=float, default=120.0)
    parser.add_argument("--update-seconds", type=float, default=12.0)
    parser.add_argument("--output-dir", default="")
    args = parser.parse_args()
    probe = Probe(args)
    try:
        return probe.run()
    except Pending as exc:
        probe.record(f"PENDING: {exc}")
        probe.record("unobserved cases remain pending; no native-IME result is claimed for them")
        probe.record(f"transcript: {probe.transcript}; observation log: {probe.obs_log}")
        return 3


if __name__ == "__main__":
    raise SystemExit(main())

