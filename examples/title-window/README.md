# Dagda SDL3 Title Window (`examples/title-window`)

First Linux SDL3 host for the Dagda shared-title milestone. It opens a real SDL3 window showing one editable slide title backed by a tiny local model fixture behind a narrow callback boundary.

## Linux dependencies

- **Pinned Odin compiler**: installed via `bash scripts/setup-odin.sh` and invoked through `./scripts/odin.sh`.
- **SDL3 shared library (`libSDL3.so`)** and standard Linux display stack (Wayland or X11):
  - Arch Linux: `pacman -S sdl3`
  - Debian / Ubuntu: `apt install libsdl3-dev`
  - Fedora: `dnf install SDL3-devel`

Text rendering uses SDL3's built-in `SDL_RenderDebugText`, so no `SDL3_ttf` or other extra native libraries are required.

## Build, test, and run

From the repository root:

```sh
# Run unit tests (injected SDL3 events, no display required)
./scripts/odin.sh test examples/title-window -collection:dagda=.

# Build the Linux window binary
./scripts/odin.sh build examples/title-window -collection:dagda=. -out:build/title-window

# Run interactively on a Linux Wayland/X11 desktop
./scripts/odin.sh run examples/title-window -collection:dagda=.
```

### Interactive controls

- **Type / IME**: commits replacement text once per `SDL_EVENT_TEXT_INPUT` operation. Active `SDL_EVENT_TEXT_EDITING` preedit text is rendered separately in amber with an underline and never mutates the model.
- **Escape**: cancels active composition cleanly (`SDL_ClearComposition`) without losing keyboard focus.
- **Ctrl+Z**: calls the model adapter's `undo` callback and preserves keyboard focus.
- **Left / Right / Home / End** (with optional **Shift**), **Ctrl+A**, **Backspace**, **Delete**: UTF-8 rune-aware caret, selection, and single-commit edits.
- **Click inside / outside the title box**: focuses or blurs the title.
- **F2**: triggers a simulated external rename through the adapter, gated by `window_external_commit_gate` (blocked while composing; redraws without stealing focus when ready).

### Reproducible real-window demo & capture

```sh
./scripts/odin.sh run examples/title-window -collection:dagda=. -- --demo-capture build/title-window-capture
```

This opens a real SDL3 window, injects a deterministic sequence of events (active composition + blocked external rename, Escape cancel, external rename redraw with focus preserved, and `Ctrl+Z` undo), prints a step-by-step transcript, and writes PNG captures of the rendered window (`01-composing-busy.png`, `02-external-rename.png`, `03-after-undo.png`).

## Integration boundary for Round 3

- **`Model_Adapter`** (`adapter.odin`): three narrow callbacks (`snapshot`, `commit`, `undo`) plus `ctx: rawptr`. Replace `fixture_adapter(&fixture)` with the real shared title model adapter without changing the window or editor code.
- **Composition busy gate**: call `window_external_commit_gate(&win)` (or `editor_external_commit_gate(&state)`) before applying an external commit. It returns `.Busy_Composing` while SDL preedit text is active so the integration layer can return a retryable busy response instead of colliding with an in-progress IME composition.
- **External model updates**: call `editor_sync_from_model(&win.editor, adapter)` when the model changes externally; it updates the cached snapshot, clamps caret/selection to valid UTF-8 boundaries, marks `needs_redraw`, and preserves `focused`.
