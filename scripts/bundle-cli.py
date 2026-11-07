#!/usr/bin/env python3
"""Build-time source embedding; the distributed CLI and generated apps use Odin."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    pin = json.loads((ROOT / 'dagda.lock').read_text())['odin']
    compiler = ROOT / '.tools' / f"odin-{pin['version']}" / 'odin'
    actual = subprocess.check_output([str(compiler), 'version'], text=True).strip().split()[-1]
    if actual != pin['compiler_version']:
        raise SystemExit('Pinned compiler version mismatch; CLI bundle not created')
    paths = sorted([p for p in (ROOT / 'dagda').rglob('*.odin') if not p.name.endswith('_test.odin')]
                   + list((ROOT / 'vendor/odin-http').glob('*.odin'))
                   + [ROOT / p for p in ('native/platform.c', 'dagda.lock', 'vendor/odin-http/LICENSE',
                                        'vendor/odin-http/DAGDA.md', 'vendor/odin-http/README.md', 'patches/odin-http.patch')])
    files = []
    for path in paths:
        if path.is_symlink():
            raise SystemExit('Refusing symlink in framework bundle')
        data = path.read_bytes()
        files.append({'path': path.relative_to(ROOT).as_posix(), 'content': data.decode(),
                      'sha256': hashlib.sha256(data).hexdigest()})
    digest = hashlib.sha256(''.join(f"{f['path']}\n{f['sha256']}\n" for f in files).encode()).hexdigest()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--',
                                'dagda', 'native', 'vendor', 'dagda.lock', 'patches'], cwd=ROOT).strip():
        revision += '-dirty'
    templates = [{'path': p.relative_to(ROOT / 'templates').as_posix(), 'content': p.read_text()}
                 for p in sorted((ROOT / 'templates').rglob('*')) if p.is_file()]
    bundle = {'format': 1, 'revision': revision, 'source_id': digest, 'compiler': pin,
              'files': files, 'templates': templates}
    (ROOT / 'build').mkdir(exist_ok=True)
    (ROOT / 'build/cli-bundle.json').write_text(json.dumps(bundle, ensure_ascii=False, indent=2) + '\n')

if __name__ == '__main__':
    main()
