#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform_key="linux-amd64" ;;
  Darwin-arm64) platform_key="macos-arm64" ;;
  *)
    echo "The current compiler pin supports Linux x86_64 and macOS ARM64 only." >&2
    exit 1
    ;;
esac
for dependency in python3 curl tar; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 1; }
done

pin=()
while IFS= read -r line; do
  pin+=("$line")
done < <(PLATFORM_KEY="$platform_key" python3 - <<'PY'
import json, os
data = json.load(open('dagda.lock'))
p = data.get('platforms', {}).get(os.environ['PLATFORM_KEY'], data['odin'])
print(p['version'])
print(p['url'])
print(p['sha256'])
PY
)
destination="$PWD/.tools/odin-${pin[0]}"
if [[ -x "$destination/odin" ]]; then
  "$destination/odin" version
  exit 0
fi
mkdir -p .tools
stage=$(mktemp -d "$PWD/.tools/install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
archive="$stage/odin.tar.gz"
if [[ $# -eq 1 ]]; then
  cp -- "$1" "$archive"
elif [[ $# -eq 0 ]]; then
  curl --fail --location --retry 2 --connect-timeout 15 "${pin[1]}" --output "$archive"
else
  echo 'Usage: bash scripts/setup-odin.sh [existing-release-archive]' >&2
  exit 1
fi
ARCHIVE_PATH="$archive" EXPECTED_SHA="${pin[2]}" python3 - <<'PY' || {
import hashlib, os, sys
actual = hashlib.sha256(open(os.environ['ARCHIVE_PATH'], 'rb').read()).hexdigest()
if actual != os.environ['EXPECTED_SHA']:
    print('Odin release checksum mismatch; nothing installed.', file=sys.stderr)
    sys.exit(1)
PY
  exit 1
}
mkdir "$stage/unpacked"
tar -xzf "$archive" -C "$stage/unpacked"
compiler=$(python3 - "$stage/unpacked" <<'PY'
from pathlib import Path
import sys
candidates = [p for p in Path(sys.argv[1]).rglob('odin') if p.is_file() and (p.parent / 'core').is_dir()]
if len(candidates) != 1:
    sys.exit('Expected one compiler beside its core library in the verified archive')
print(candidates[0].parent)
PY
)
"$compiler/odin" version
mv -- "$compiler" "$destination"
echo "Installed Odin at $destination/odin"
echo 'Use ./scripts/odin.sh for the pinned compiler.'
