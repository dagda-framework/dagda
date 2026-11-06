#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror -O2 -c native/platform.c -o build/platform.o
./scripts/odin.sh test dagda/db -out:build/db-tests -debug "$@"
./scripts/odin.sh test cmd/runtime-proof -out:build/adapter-tests -debug "$@"
./scripts/odin.sh test dagda/runtime -out:build/runtime-tests -debug "$@"
