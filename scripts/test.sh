#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "$@"
python3 -m unittest discover -s tests -p 'test_*.py'
./scripts/test-unit.sh "$@"
python3 tests/integration.py
python3 tests/failures.py
python3 tests/application.py
python3 tests/json_api.py
python3 tests/validation_api.py
python3 tests/cli.py
python3 tests/database.py
