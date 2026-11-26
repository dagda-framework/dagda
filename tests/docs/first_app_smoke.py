#!/usr/bin/env python3
"""Docs smoke test: build the first-app guide exactly as published.

Extracts the guide's Odin snippet verbatim into a fresh
my-counter project beside a temporary Dagda root whose build/
directory starts absent, then runs the guide's first two shell
build blocks in order, in ONE Bash process (the first block
does `cd my-counter`, and the guide promises the reader is
still there for the second). The commands are read from the
guide, so future documentation edits are exercised too.

The temporary Dagda root is assembled from symlinks to the
real checkout's sources plus its own real (initially absent)
build/ directory. The test only ever removes the temporary
tree it created; the caller's checkout build/ is never touched.
"""
import os
import re
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDE = Path(os.environ.get("GUIDE_PATH", ROOT / "docs" / "first-app.md"))


def fenced_blocks(text, lang):
    return re.findall(rf"```{lang}\n(.*?)```", text, re.S)


def main():
    guide = GUIDE.read_text()
    snippets = fenced_blocks(guide, "odin")
    assert len(snippets) == 1, f"expected exactly one published Odin snippet, found {len(snippets)}"
    build_section = guide.split("## Build and run", 1)[1]
    blocks = fenced_blocks(build_section, "sh")
    assert len(blocks) >= 2, "guide is missing its two build blocks"

    tmp = Path(tempfile.mkdtemp(prefix="dagda-first-app-smoke-"))
    try:
        # Temporary Dagda root beside my-counter: source entries
        # are symlinks into the real checkout; build/ is the
        # test's own real directory and starts absent.
        dagda_root = tmp / "dagda"
        dagda_root.mkdir()
        for name in ("scripts", "dagda", "examples", ".tools", "dagda.lock"):
            (dagda_root / name).symlink_to(ROOT / name, target_is_directory=(ROOT / name).is_dir())
        project = tmp / "my-counter"
        project.mkdir()
        (project / "main.odin").write_text(snippets[0])

        env = {**os.environ, "DAGDA": str(dagda_root)}
        script = "\n".join(blocks[:2])  # one Bash process for both blocks
        subprocess.check_call(["bash", "-e", "-c", script], cwd=tmp, env=env)

        app_bin = project / "my-counter"
        client_bin = dagda_root / "build" / "dagda-client"
        for binary in (app_bin, client_bin):
            mode = binary.stat().st_mode
            assert stat.S_ISREG(mode) and os.access(binary, os.X_OK), \
                f"{binary} is not a regular executable file (mode {oct(mode)})"
        print(f"first-app smoke: built {app_bin} and {client_bin} from the published guide")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
