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

Machine assertions (callback trace, driver replies, inspected
text/revision/undo) are kept distinct from visual observations
(marked-text updates, focus survival): a delay and a printed
cue cannot establish those. The operator answers three
yes/no/unknown questions only after the window sequence, so
focus stays in the Dagda window throughout; any answer that
is not "yes" withholds the all-pass exit. A green hosted job
that reaches CUE 1 and receives no input is a pending native
run: its input source was a supplied label, unattended, and
no composition start was received.
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
import uuid
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


ORIGINAL_HEX = ORIGINAL.encode("utf-8").hex()


def _check_entry(entry, kind, field, rev, undo, text_hex):
    want = {"kind": kind, "field": str(field), "a_rev": str(rev), "a_undo": str(undo), "a_text_hex": text_hex}
    for key, value in want.items():
        if entry.get(key) != value:
            raise AssertionError(f"trace entry mismatch: want {key}={value!r} in {want}, got {entry}")


def _check_common(entries, count):
    if len(entries) != count:
        raise AssertionError(f"trace length mismatch: want {count} records, got {len(entries)}: {entries}")
    for i, entry in enumerate(entries):
        if entry.get("seq") != str(i):
            raise AssertionError(f"trace sequence mismatch at record {i}: {entries}")
        if entry.get("tid") != entry.get("main_tid"):
            raise AssertionError(f"callback off the host thread at record {i}: {entry}")
        if i > 0 and entry.get("video") != "cocoa":
            raise AssertionError(f"native Cocoa path not verified at record {i} (video={entry.get('video')!r}): {entry}")
    ready = entries[0]
    if ready.get("kind") != "ready" or ready.get("a_rev") != "1" or ready.get("a_undo") != "0" or ready.get("a_text_hex") != ORIGINAL_HEX:
        raise AssertionError(f"trace ready record mismatch: {ready}")


def validate_trace_at_start(entries):
    """Exactly [ready, start(1)] with title A at rev=1, undo=0."""
    _check_common(entries, 2)
    _check_entry(entries[1], "composition_start", A_CANVAS_ID, 1, 0, ORIGINAL_HEX)


def validate_trace_at_commit(entries):
    """[ready, start(1), commit(1), end(1)]; returns supplied text."""
    _check_common(entries, 4)
    _check_entry(entries[1], "composition_start", A_CANVAS_ID, 1, 0, ORIGINAL_HEX)
    commit = entries[2]
    if commit.get("kind") != "commit" or commit.get("field") != str(A_CANVAS_ID) or commit.get("accepted") != "true":
        raise AssertionError(f"trace commit record mismatch: {commit}")
    if commit.get("rev") != "2" or commit.get("undo") != "1" or not commit.get("text_hex"):
        raise AssertionError(f"trace commit revision/undo/bytes mismatch: {commit}")
    supplied_hex = commit["text_hex"]
    _check_entry(entries[3], "composition_end", A_CANVAS_ID, 2, 1, supplied_hex)
    return hex_text(supplied_hex)


def validate_complete_trace(entries):
    """Full expected trace, including the final cancel pair.

    Exactly: start(1), one accepted commit(1), end(1),
    start(1), end(1) after the ready record, all on the host
    thread under Cocoa, with title A at rev 1/undo 0, then
    rev 2/undo 1 with the supplied bytes from the commit on.
    Returns the supplied text.
    """
    if len(entries) >= 4:
        validate_trace_at_commit(entries[:4])
    _check_common(entries, 6)
    supplied_hex = entries[2]["text_hex"]
    _check_entry(entries[4], "composition_start", A_CANVAS_ID, 2, 1, supplied_hex)
    _check_entry(entries[5], "composition_end", A_CANVAS_ID, 2, 1, supplied_hex)
    return hex_text(supplied_hex)


def _synthetic_entries(second_field=A_CANVAS_ID, extra_pairs=0, supplied="かな"):
    supplied_hex = supplied.encode("utf-8").hex()
    entries = [
        {"seq": "0", "kind": "ready", "tid": "7", "main_tid": "7", "a_rev": "1", "a_undo": "0", "a_text_hex": ORIGINAL_HEX},
        {"seq": "1", "kind": "composition_start", "field": "1", "tid": "7", "main_tid": "7", "video": "cocoa", "a_rev": "1", "a_undo": "0", "a_text_hex": ORIGINAL_HEX},
        {"seq": "2", "kind": "commit", "field": "1", "tid": "7", "main_tid": "7", "video": "cocoa", "accepted": "true", "text_hex": supplied_hex, "rev": "2", "undo": "1"},
        {"seq": "3", "kind": "composition_end", "field": "1", "tid": "7", "main_tid": "7", "video": "cocoa", "a_rev": "2", "a_undo": "1", "a_text_hex": supplied_hex},
        {"seq": "4", "kind": "composition_start", "field": str(second_field), "tid": "7", "main_tid": "7", "video": "cocoa", "a_rev": "2", "a_undo": "1", "a_text_hex": supplied_hex},
        {"seq": "5", "kind": "composition_end", "field": str(second_field), "tid": "7", "main_tid": "7", "video": "cocoa", "a_rev": "2", "a_undo": "1", "a_text_hex": supplied_hex},
    ]
    seq = 6
    for _ in range(extra_pairs):
        for kind in ("composition_start", "composition_end"):
            entries.append({"seq": str(seq), "kind": kind, "field": str(second_field), "tid": "7", "main_tid": "7",
                            "video": "cocoa", "a_rev": "2", "a_undo": "1", "a_text_hex": supplied_hex})
            seq += 1
    return entries


def _write_obs(path, entries):
    path.write_text("".join(" ".join(f"{k}={v}" for k, v in e.items()) + "\n" for e in entries), encoding="utf-8")


def _finalize_probe(tmp, entries):
    probe = object.__new__(Probe)
    probe.args = argparse.Namespace(stage_timeout=1.0)
    probe.out = tmp
    probe.transcript = tmp / "transcript.txt"
    probe.obs_log = tmp / "composition-obs.log"
    _write_obs(probe.obs_log, entries)

    class _ExitedProc:
        def wait(self, timeout):
            return 0

    probe.proc = _ExitedProc()
    probe.operator_answers = lambda: {
        "two_distinct_marked_updates": "yes",
        "marked_text_and_focus_survived_preview": "yes",
        "second_preedit_in_a_canvas_before_cancel": "yes",
    }
    return probe


def self_test_trace():
    valid = _synthetic_entries()
    supplied = validate_complete_trace(valid)
    print(f"self-test valid trace: PASS (supplied={supplied!r})")
    for label, entries in [
        ("wrong-field", _synthetic_entries(second_field=2)),
        ("wrong-field/extra-pair", _synthetic_entries(second_field=2, extra_pairs=1)),
    ]:
        try:
            validate_complete_trace(entries)
        except AssertionError as exc:
            print(f"self-test {label} counterexample: FAIL as required ({str(exc)[:160]})")
            continue
        raise AssertionError(f"{label} counterexample trace unexpectedly passed validation")
    print("self-test verdicts differ: PASS")

    # Finalization path: a clean close passes, but a field-2
    # pair appended during the close wait must overturn the
    # pre-close verdict when the log is reread after exit.
    supplied_hex = "かな".encode("utf-8").hex()
    late = _synthetic_entries() + [
        {"seq": "6", "kind": "composition_start", "field": "2", "tid": "7", "main_tid": "7", "video": "cocoa", "a_rev": "2", "a_undo": "1", "a_text_hex": supplied_hex},
        {"seq": "7", "kind": "composition_end", "field": "2", "tid": "7", "main_tid": "7", "video": "cocoa", "a_rev": "2", "a_undo": "1", "a_text_hex": supplied_hex},
    ]
    with tempfile.TemporaryDirectory(prefix="dagda-ime-finalize-clean.") as td:
        probe = _finalize_probe(Path(td), _synthetic_entries())
        assert probe.finalize("かな") == 0
        transcript = probe.transcript.read_text(encoding="utf-8")
        assert "machine final: post-exit trace validated (6 records" in transcript, transcript
        print("self-test finalize clean close: PASS")
    with tempfile.TemporaryDirectory(prefix="dagda-ime-finalize-late.") as td:
        probe = _finalize_probe(Path(td), late)
        try:
            probe.finalize("かな")
        except AssertionError as exc:
            print(f"self-test finalize late field-2 pair: FAIL as required ({str(exc)[:160]})")
        else:
            raise AssertionError("late-pair finalization unexpectedly passed")
    print("self-test finalization verdicts differ: PASS")
    return 0


class Probe:
    def __init__(self, args):
        self.args = args
        # Each run gets a tagged, isolated directory, so a
        # reused --output-dir can never contribute observations
        # from an earlier run to this run's verdict.
        self.run_id = uuid.uuid4().hex[:12]
        base_out = Path(args.output_dir) if args.output_dir else Path(tempfile.mkdtemp(prefix="dagda-native-ime."))
        self.out = base_out / f"run-{self.run_id}"
        self.out.mkdir(parents=True, exist_ok=False)
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

    def finalize(self, supplied):
        """Close out the run after the undo stage.

        The fixture can still append callbacks until the host
        actually exits, so the pre-close trace is never the
        verdict. After a successful exit this rereads the
        run-specific log, validates that post-exit snapshot
        against the expected trace and the supplied committed
        bytes, and uses only that snapshot for the final
        transcript and verdict, before the operator questions.
        """
        self.record("CUE 5: Close the Dagda window now. After it closes, focus this terminal for the operator questions.")
        try:
            rc = self.proc.wait(timeout=self.args.stage_timeout)
        except subprocess.TimeoutExpired as exc:
            raise Pending(f"window close not observed within {self.args.stage_timeout:.0f}s") from exc
        assert rc == 0, f"host exited with status {rc} after window close"
        self.proc = None
        post_exit_entries = self.obs()
        post_exit_supplied = validate_complete_trace(post_exit_entries)
        assert post_exit_supplied == supplied, (
            f"post-exit committed bytes mismatch: trace supplied {post_exit_supplied!r}, expected {supplied!r}")
        self.record(f"machine final: post-exit trace validated ({len(post_exit_entries)} records, supplied={post_exit_supplied!r}); any callback appended during the close wait is included in this snapshot")
        for entry in post_exit_entries:
            self.record(f"final trace record: {entry}")
        answers = self.operator_answers()
        unconfirmed = [key for key, value in answers.items() if value != "yes"]
        if unconfirmed:
            raise Pending(f"machine stages passed but visual observations were not confirmed (need yes): {unconfirmed} answers={answers}")
        self.record("all native IME cases observed (machine trace, driver checks, and operator visual confirmations)")
        return 0

    def operator_answers(self):
        """Collect visual confirmations after the window sequence.

        Asked only once the Dagda window is closed, so the
        operator kept keyboard focus in it throughout. Each
        answer is recorded verbatim-normalized; anything other
        than yes (including EOF in an unattended run) is a
        missing visual observation, never a pass.
        """
        questions = [
            ("two_distinct_marked_updates", "During the FIRST composition, did the marked text visibly change in at least two distinct updates?"),
            ("marked_text_and_focus_survived_preview", "While still composing after the automatic driver preview, did the marked text and caret remain visible in the A canvas field with that field still focused?"),
            ("second_preedit_in_a_canvas_before_cancel", "During the SECOND composition, did marked text appear in the A canvas field before you cancelled it?"),
        ]
        self.record("operator confirmation questions (visual observations only; machine results above stand separately)")
        answers = {}
        for key, question in questions:
            try:
                raw = input(f"{question} [yes/no/unknown] ").strip().lower()
            except EOFError:
                raw = ""
            normalized = {"yes": "yes", "y": "yes", "no": "no", "n": "no"}.get(raw, "unknown" if raw else "missing")
            answers[key] = normalized
            self.record(f"operator confirmation {key}: {normalized} (raw={raw!r})")
        return answers

    def environment(self):
        self.record(f"platform: system={platform.system()} machine={platform.machine()} release={platform.release()}")
        if platform.system() == "Darwin":
            for cmd in (["sw_vers"], ["defaults", "read", "com.apple.HIToolbox", "AppleSelectedInputSources"]):
                try:
                    out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                    self.record(f"{' '.join(cmd)} -> exit={out.returncode} {(out.stdout or out.stderr).strip()[:400]!r}")
                except Exception as exc:
                    self.record(f"{' '.join(cmd)} failed: {exc!r}")
        self.record(f"run id: {self.run_id} (observations isolated under {self.out})")
        self.record(f"input source label (supplied by the operator, not verified by the probe): {self.args.input_source}")
        self.record(f"keys (operator-supplied): {self.args.keys}")
        self.record(f"input method: native macOS IME via SDL text input (no --control-stdin), separate dagda-client over a private socket")
        self.record("note: reaching CUE 1 with no composition start is a pending native run, not a pass")
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
        assert not self.obs_log.exists(), f"observation log already exists for run {self.run_id}: {self.obs_log}"
        env = {**os.environ, "COMPOSITION_OBS_LOG": str(self.obs_log)}
        # Native Cocoa path required: strip any inherited dummy
        # or offscreen SDL drivers so SDL uses its macOS default
        # (cocoa); the trace also verifies video=cocoa per record.
        inherited_video = env.pop("SDL_VIDEODRIVER", None)
        env.pop("SDL_AUDIODRIVER", None)
        self.record(f"child SDL_VIDEODRIVER: inherited {inherited_video!r} removed; SDL default (cocoa on macOS) required and verified from the trace")
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
                                      lambda: self.obs() if len(self.obs()) >= 2 else None,
                                      self.args.stage_timeout)
            validate_trace_at_start(entries)
            self.record(f"machine step 1a: exact trace [ready, start(1) rev=1 undo=0] on the host thread under Cocoa: {entries[1]}")
            self.record(f"CUE 1b: Keep composing for the next {self.args.update_seconds:.0f} seconds. "
                        f"Visual observations (two distinct marked-text updates, and marked text/focus "
                        f"surviving the preview) are NOT established by this delay or cue; you will be "
                        f"asked about them after the window closes. Do not accept yet.")
            time.sleep(self.args.update_seconds)
            validate_trace_at_start(self.obs())
            code, preview = self.client("preview", str(A_OUTLINE_ID), "rename", "1", "text", "Agent draft")
            assert code == 0 and preview.get("ok") is True, preview
            for role in ("a.canvas", "a.outline"):
                el = self.inspect(role)
                assert el["text"] == ORIGINAL, (role, el)
            st = self.status()
            assert st["a_rev"] == 1 and st["a_undo"] == 0, st
            validate_trace_at_start(self.obs())
            self.record("machine step 1b: preview succeeded during the composition; trace still exactly [ready, start(1)], committed bytes, revision and undo depth survived (visual survival remains an operator question)")

            # 2. Accept the candidate; stale driver commit must fail.
            self.record(f"CUE 2: Accept the candidate through the input source now (for example {self.args.accept_key}). Type nothing else.")
            self.wait_until("composition commit + end #1",
                            lambda: self.obs() if len(self.obs()) >= 4 else None,
                            self.args.stage_timeout)
            supplied = validate_trace_at_commit(self.obs())
            self.record(f"machine step 2a: exact trace [ready, start(1), commit(1) accepted rev=2 undo=1, end(1) rev=2 undo=1]; supplied text={supplied!r} bytes={supplied.encode('utf-8')!r}")
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
            self.wait_until("composition start/end #2 (cancel)",
                            lambda: self.obs() if len(self.obs()) >= 6 else None,
                            self.args.stage_timeout)
            supplied_again = validate_complete_trace(self.obs())
            assert supplied_again == supplied, (supplied_again, supplied)
            for role in ("a.canvas", "a.outline"):
                assert self.inspect(role)["text"] == supplied, role
            st = self.status()
            assert st["a_rev"] == 2 and st["a_undo"] == 1, st
            self.record("machine step 3a: complete trace is exactly start(1), one accepted commit(1), end(1), start(1), end(1) with rev/undo/bytes as documented; no extra pair and no commit from the cancel; committed state unchanged")
            self.record("CUE 4: Press Command+Z once in the A canvas field.")
            def undone():
                el = self.inspect("a.canvas")
                st2 = self.status()
                return (el, st2) if el["text"] == ORIGINAL and st2["a_rev"] == 3 and st2["a_undo"] == 0 else None
            el, st = self.wait_until("Command+Z undo to original", undone, self.args.stage_timeout)
            assert self.inspect("a.outline")["text"] == ORIGINAL
            assert validate_complete_trace(self.obs()) == supplied
            self.record(f"machine step 3b: Command+Z restored {ORIGINAL!r} bytes={ORIGINAL.encode('utf-8')!r} at rev={st['a_rev']} undo={st['a_undo']} (pre-close trace check only; the verdict snapshot is taken after host exit)")
            return self.finalize(supplied)
        finally:
            base.stop_process(self.proc)
            self.proc = None
            shutil.rmtree(tmp, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-source", default="", help='e.g. "Japanese - Romaji" or "Pinyin - Simplified"')
    parser.add_argument("--self-test-trace", action="store_true", help="exercise the trace verdict on a valid trace and the wrong-field/extra-pair counterexample, then exit")
    parser.add_argument("--keys", default="Command+A; romaji/pinyin syllables updating the preedit at least twice; Return accepts; Escape cancels; Command+Z undoes")
    parser.add_argument("--accept-key", default="Return")
    parser.add_argument("--stage-timeout", type=float, default=120.0)
    parser.add_argument("--update-seconds", type=float, default=12.0)
    parser.add_argument("--output-dir", default="")
    args = parser.parse_args()
    if args.self_test_trace:
        return self_test_trace()
    if not args.input_source:
        parser.error("--input-source is required unless --self-test-trace is given")
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

