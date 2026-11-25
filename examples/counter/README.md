# Dagda Native Counter (`examples/counter`)

First independent native Dagda app built directly on the public `dagda` element/action API (`dagda/element.odin`), reusable SDL3 host (`dagda/sdlhost`), and reusable local inspection/action driver (`dagda/driver`).

The entire application lives in `examples/counter/main.odin`: it owns an integer initialized to `0`, declares a `.Label` (`counter.value`) and a `.Button` (`counter.increment`), and supplies one `Action_Handler` that increments the integer on `.Activate`. Both pointer clicks and external driver invocations resolve through the same `dagda.Frame` bounds and handler.

## Linux dependencies

- Pinned Odin compiler (`bash scripts/setup-odin.sh`, invoked via `./scripts/odin.sh`)
- SDL3 (`libSDL3.so`), FreeType2 (`libfreetype.so`), and a sans-serif TrueType font (Liberation Sans / DejaVu Sans / Noto Sans, or `$DAGDA_FONT`)

## Build and run

From the repository root:

```sh
mkdir -p build
./scripts/odin.sh build examples/counter -collection:dagda=. -out:build/counter
./scripts/odin.sh build examples/dagda-client -collection:dagda=. -out:build/dagda-client

# Run standalone
./build/counter

# Run with local inspection/action Unix socket in a private directory
SOCK_DIR=$(mktemp -d /tmp/dagda-counter.XXXXXX)
SOCK=$SOCK_DIR/counter.sock
./build/counter --socket "$SOCK" &
./build/dagda-client "$SOCK" inspect counter.value
./build/dagda-client "$SOCK" inspect counter.increment
./build/dagda-client "$SOCK" invoke 2 activate
./build/dagda-client "$SOCK" inspect counter.value
```

## Acceptance test

```sh
python3 examples/counter/tests/acceptance_test.py build/counter-capture
```

This launches the real SDL3 counter window at `0` with `--socket` and `--control-stdin`, inspects `counter.value` and discovers `counter.increment`'s ID, resolved bounds, and `activate` action from a separate `dagda-client` process, injects a real SDL3 mouse click (`SDL_PushEvent` `MOUSE_BUTTON_DOWN` + `MOUSE_BUTTON_UP`) at the center of the discovered bounds to increment to `1`, invokes `activate` via `dagda-client` using the discovered ID to increment to `2`, verifies out-of-bounds clicks and unsupported actions leave the count unchanged, and captures PNGs of the live window.
