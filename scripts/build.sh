#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror -O2 -c native/platform.c -o build/platform.o
./scripts/odin.sh build cmd/runtime-proof -out:build/dagda-m0 -debug "$@"
