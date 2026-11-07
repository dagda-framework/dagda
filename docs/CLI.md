# Dagda CLI (M1)

The Odin CLI implements `new`, `doctor`, `build`, and `test`. It embeds a framework
snapshot and starter template, so the binary can generate applications outside
this checkout without downloading source or invoking Git. Linux x86_64 is the
current supported platform.

## Build and try it

From this repository, with the pinned compiler installed:

```sh
./scripts/build.sh
export PATH="$(pwd)/build:$PATH"
export DAGDA_ODIN="$(pwd)/.tools/odin-dev-2026-11a/odin"
cd /tmp
dagda new billing --dry-run
dagda new billing
cd billing
dagda doctor
dagda test
dagda build
```

Choose an unused destination name. Names begin with a lowercase letter and use
only lowercase letters, digits, and underscores, up to 48 characters. `new`
creates a child of the current directory; an existing destination is always an
error. Preview writes nothing. A failed generation preserves its partial output
for inspection instead of deleting files.

Generation produces:

- `app/main.odin`, `app/routes.odin`, and Odin request tests.
- `dagda.json` with the application name and manifest format.
- `dagda.lock` with the framework revision, source digest, file checksums, and
  exact compiler release/version/URL/archive checksum.
- `vendor/dagda/` containing the framework, native shim, and patched HTTP source.
- `.env.example`, `.gitignore`, `compose.yaml`, and application instructions.

Commit application source, manifests, and the vendored snapshot. Application
source belongs to you; build commands do not regenerate it. Source checksums
catch drift and unexpected framework files, including symlinks. They are not
signatures or an authenticity guarantee for an untrusted project.

## Commands

| Command | Current behavior |
| --- | --- |
| `new NAME [--dry-run]` | Generate the starter, refusing collisions; optionally list its files |
| `doctor [--database]` | Verify the lock, compiler version, C compiler, and libpq 17+; check app configuration when a database URL is supplied; optionally connect and query |
| `build [--release]` | Compile the native shim and app to `build/NAME`; write `build/build-info.json`; release uses Odin speed optimization with assertions retained |
| `test` | Compile and run the application's Odin tests; return nonzero on compilation or test failure |
| `--version` | Show CLI version, embedded framework revision, and snapshot digest |

Run `doctor`, `build`, and `test` from the generated project root. Compiler lookup
uses `DAGDA_ODIN`, then `.tools/odin-<release>/odin`, then `odin` on PATH. The
reported version must match the lock. The CLI does not install compilers or
resolve dependencies from the network. Native libraries still come from the
host system; the lock does not make builds hermetic or byte-for-byte reproducible.

Without `DAGDA_DATABASE_URL`, ordinary `doctor` checks tools and sources, explicitly
reports configuration as unchecked, and succeeds. `doctor --database` requires
that variable and checks connectivity using the configured deadline. With a URL,
configuration validation runs through the application's `check` command. Diagnostics
omit database values and credentials. Doctor builds its checker separately so it
can run while the normal application binary is serving.

## Run the generated app

Its README contains the full setup. The optional Compose file runs a local
PostgreSQL instance on loopback port 55432 with development-only credentials.
Starting it is explicit:

```sh
docker compose up -d --wait
cp .env.example .env
set -a
. ./.env
set +a
dagda doctor --database
./build/billing serve
```

Neither CLI nor runtime automatically loads `.env`. You can supply an existing
local PostgreSQL connection instead. Runtime connections currently accept Unix
sockets or numeric loopback addresses. The starter needs no schema migration.

`GET /` returns the application name. `POST /echo` demonstrates typed JSON and
required/length field validation. The framework provides liveness and readiness
routes. Generated Odin tests use the in-process client and need neither a running
database nor io_uring; serving HTTP needs both permitted io_uring and PostgreSQL.

## Verification and limits

Three CLI tests in `cmd/dagda` cover names/paths/checksums, collision prevention,
preview, vendor drift, independent generated builds, passing request tests, and
nonzero compiler/test failures. The generated build test uses a temporary path
containing spaces and `$` to exercise argument handling. These tests pass locally.

`tests/cli.py` additionally copies the CLI outside this checkout, checks compiler
mismatch and redacted configuration failures, builds a release app, then uses
an isolated PostgreSQL fixture to exercise doctor and the generated API over HTTP.
It is included in `scripts/test.sh`. The complete suite passed on 2026-11-06:
38 Odin tests, 7 Python harness tests, and six integration suites, including the
generated release app. Its two request tests also pass through the copied CLI.
See the [validation record](validation/2026-11-06-cli.json).

This is the M1 CLI skeleton. Watch/restart, resource generation, migrations,
database orchestration, route listing, jobs, deployment packaging, automatic
upgrades, and macOS support remain later work. `--release` currently writes build
metadata, not a container recipe. Packaging a public CLI release and choosing the
framework license remain separate decisions.
