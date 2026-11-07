#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror -O2 -c native/platform.c -o build/platform.o
./scripts/odin.sh build cmd/runtime-proof -out:build/dagda-m0 -debug "$@"
./scripts/odin.sh build examples/api -out:build/dagda-api -debug "$@"
python3 scripts/bundle-cli.py
./scripts/odin.sh build cmd/dagda -out:build/dagda -debug "$@"
