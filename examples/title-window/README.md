# Dagda SDL3 Title Window (`examples/title-window`)

Linux SDL3 host for the Dagda shared-title milestone. It opens a real SDL3 window showing one editable slide title backed by `examples/title-model` through a narrow callback boundary, rendering committed and composing UTF-8 text with real TrueType glyphs via FreeType2.

## Linux dependencies

- **Pinned Odin compiler**: installed via `bash scripts/setup-odin.sh` and invoked through `./scripts/odin.sh`.
- **SDL3 (`libSDL3.so`)**, **FreeType2 (`libfreetype.so`)**, and a standard sans-serif TrueType font (e.g. Liberation Sans, DejaVu Sans, or Noto Sans):
  - Arch Linux: `pacman -S sdl3 freetype2 ttf-liberation`
  - Debian / Ubuntu: `apt install libsdl3-dev libfreetype-dev fonts-liberation`
  - Fedora: `dnf install SDL3-devel freetype-devel liberation-sans-fonts`
- **Custom font path (optional)**: set `DAGDA_FONT=/path/to/font.ttf` to override the default system font search (`/usr/share/fonts/liberation/LiberationSans-Regular.ttf`, DejaVu Sans, Noto Sans).

## Build, test, and run (from a fresh checkout)

From the repository root:

```sh
# Install the pinned Odin compiler if not already present
bash scripts/setup-odin.sh

# Run unit tests (injected SDL3 events + headless FreeType glyph/layout checks; no display required)
./scripts/odin.sh test examples/title-window -collection:dagda=.

# Build the Linux window binary
mkdir -p build
./scripts/odin.sh build examples/title-window -collection:dagda=. -out:build/title-window

# Run interactively on a Linux Wayland/X11 desktop
./scripts/odin.sh run examples/title-window -collection:dagda=.
```

### Interactive controls

- **Type / IME (including non-ASCII such as `café` / `español` / `ñ`)**: commits replacement text once per `SDL_EVENT_TEXT_INPUT` operation. Active `SDL_EVENT_TEXT_EDITING` preedit text is rendered inline in amber with an underline, honors `start`/`length` preedit caret and selection, replaces any selected committed range visually while composing, and never mutates the model.
- **Escape**: cancels active composition cleanly (`SDL_ClearComposition`) without losing keyboard focus or the underlying committed selection.
- **Ctrl+Z**: calls the model adapter's `undo` callback and preserves keyboard focus.
- **Left / Right / Home / End** (with optional **Shift**), **Ctrl+A**, **Backspace**, **Delete**: UTF-8 rune-aware caret, selection, and single-commit edits.
- **Click inside / outside the title box**: focuses or blurs the title.
- **F2**: triggers a simulated external rename through the adapter, gated by `window_external_commit_gate` (blocked while composing; redraws without stealing focus when ready).

### Reproducible real-window demo & capture

```sh
mkdir -p build
./scripts/odin.sh build examples/title-window -collection:dagda=. -out:build/title-window
./build/title-window --demo-capture build/title-window-capture
```

This opens a real SDL3 window, injects a deterministic sequence of SDL events (selecting `"results"`, composing non-ASCII `"café"` with nonterminal preedit caret `start=2` while blocking an external rename, cancelling with `Escape`, committing `"español"`, applying an external rename to `"Café & niño"` without stealing focus, and undoing with `Ctrl+Z`), asserts every expected state transition, and writes PNG captures (`01-nonascii-preedit-busy.png`, `02-nonascii-committed.png`, `03-external-rename.png`, `04-after-undo.png`). Any failed invariant or screenshot capture error exits nonzero.

## Adapter and integration boundary

- **`Model_Adapter`** (`adapter.odin`, `model_adapter.odin`): three narrow callbacks (`snapshot`, `commit`, `undo`) plus `ctx: rawptr`, wired to one window-thread `examples/title-model` `Model` instance via `title_model_adapter(&model)`. Maps all declared `title_model.Error` failures (`Unknown_Object`, `Stale_Revision`, `Invalid_Text`, `Alloc_Failed`) accurately and preserves borrowed snapshot lifetimes and one-step undo history.
- **Composition busy gate**: call `window_external_commit_gate(&win)` (or `editor_external_commit_gate(&state)`) before applying an external commit. It returns `.Busy_Composing` while SDL preedit text is active so external callers can receive a retryable busy response.
- **Unified layout (`compute_title_layout`)**: paints committed text, composing replacement, preedit selection, caret, and the `SDL_SetTextInputArea` candidate anchor from one layout pass.
- **External model updates**: call `editor_sync_from_model(&win.editor, adapter)` when the model changes externally; it refreshes the snapshot, clamps caret/selection to valid UTF-8 boundaries, marks `needs_redraw`, and preserves `focused`.
