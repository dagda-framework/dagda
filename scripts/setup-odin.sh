#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  echo 'The current compiler pin supports Linux x86_64 only.' >&2
  exit 1
fi
for dependency in python3 curl tar sha256sum; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 1; }
done

mapfile -t pin < <(python3 - <<'PY'
import json
p = json.load(open('dagda.lock'))['odin']
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
printf '%s  %s\n' "${pin[2]}" "$archive" | sha256sum --check --status || {
  echo 'Odin release checksum mismatch; nothing installed.' >&2
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
