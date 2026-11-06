#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler="$root/.tools/odin-dev-2026-11a/odin"
if [[ ! -x "$compiler" ]]; then
  echo 'Pinned Odin is missing. Run: bash scripts/setup-odin.sh' >&2
  exit 1
fi
exec "$compiler" "$@"
