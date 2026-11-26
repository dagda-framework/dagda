#!/usr/bin/env python3
"""Docs smoke test: build the first-app guide exactly as published.

Extracts the guide's Odin snippet verbatim into a fresh
my-counter project outside the checkout, then runs the guide's
first two shell build blocks in order (read from the guide, so
future documentation edits are exercised too) with the pinned
compiler and asserts that both binaries land executable.
The checkout starts with no $DAGDA/build directory, which is
what catches a missing mkdir in the client build block.
"""
import os
import re
import shutil
import subprocess
import sys
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

    build_dir = ROOT / "build"
    if build_dir.exists():
        shutil.rmtree(build_dir)  # the check owns this path; it must start absent
    tmp = Path(tempfile.mkdtemp(prefix="dagda-first-app-smoke-"))
    try:
        project = tmp / "my-counter"
        project.mkdir()
        (project / "main.odin").write_text(snippets[0])
        env = {**os.environ, "DAGDA": str(ROOT)}
        for block in blocks[:2]:
            subprocess.check_call(["bash", "-e", "-c", block], cwd=tmp, env=env)
        app_bin = project / "my-counter"
        client_bin = build_dir / "dagda-client"
        for binary in (app_bin, client_bin):
            assert binary.exists() and os.access(binary, os.X_OK), f"{binary} was not produced executable"
        print(f"first-app smoke: built {app_bin} and {client_bin} from the published guide")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(build_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
