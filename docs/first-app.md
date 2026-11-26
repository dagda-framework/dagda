# Build your first native Dagda app

This guide builds a counter window from an Odin project that lives
**outside** the Dagda checkout. The whole app is one `main.odin`:
the app owns the count, the view declares a label and a button with
stable IDs, and a window click and an agent invocation reach the
same action handler.

## Prerequisites

Linux x86-64, plus:

- The tools Dagda's pinned Odin installer needs: Python 3, curl,
  tar, and sha256sum.
- SDL3, FreeType, and a sans-serif TrueType font:
  - Debian / Ubuntu: `sudo apt-get install -y libsdl3-dev libfreetype-dev fonts-liberation`
  - Arch Linux: `pacman -S sdl3 freetype2 ttf-liberation`
  - Fedora: `dnf install SDL3-devel freetype-devel liberation-sans-fonts`
- A Dagda checkout. Below, `$DAGDA` is its path:

```sh
git clone https://github.com/dagda-framework/dagda.git
export DAGDA="$PWD/dagda"
bash "$DAGDA/scripts/setup-odin.sh"   # installs the pinned Odin compiler
```

## Directory layout

```text
my-counter/
└── main.odin
```

No other files are needed. Your project imports Dagda packages
through the `dagda` collection, which the build command points at
the checkout — Dagda itself is never copied into your project.

## The app

Save this as `my-counter/main.odin`:

```odin
package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

Counter :: struct {
	count:     int,
	label_buf: [32]u8,
	elements:  [2]dagda.Element,
}

counter_view :: proc(user_data: rawptr) -> dagda.View {
	c := (^Counter)(user_data)
	text := fmt.bprintf(c.label_buf[:], "%d", c.count)
	c.elements = {
		{info = {id = 1, role = "counter.value"}, kind = .Label, text = text},
		{info = {id = 2, role = "counter.increment"}, kind = .Button, text = "Increment"},
	}
	return {elements = c.elements[:]}
}

counter_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	c := (^Counter)(user_data)
	if id == 2 && action == .Activate {
		c.count += 1
		return true
	}
	return false
}

main :: proc() {
	counter: Counter
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: counter [--socket <socket-path>]")
		os.exit(2)
	}
	app := sdlhost.App{
		title     = "Dagda — Counter",
		width     = 360,
		height    = 180,
		user_data = &counter,
		view      = counter_view,
		handle    = counter_handle,
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
```

Three ideas to notice:

1. **The app owns the count.** `Counter.count` is plain app
   state; Dagda never stores it. The view re-reads it on rebuild.
2. **Stable IDs and roles.** The label is always element `1`
   (`counter.value`) and the button always element `2`
   (`counter.increment`), however the window is resized.
3. **One handler, two callers.** A pointer click resolves to
   element `2`'s `Activate` action, and an agent invoking that
   same ID calls `counter_handle` identically — there is no
   separate agent code path.

## Build and run

From your project directory:

```sh
cd my-counter
"$DAGDA/scripts/odin.sh" build . -collection:dagda="$DAGDA" -out:my-counter
```

Still in `my-counter`, build the agent client once. The source
is given as an absolute path inside the checkout, so this also
works when the checkout has no `build/` directory yet:

```sh
mkdir -p "$DAGDA/build"
"$DAGDA/scripts/odin.sh" build "$DAGDA/examples/dagda-client" -collection:dagda="$DAGDA" -out:"$DAGDA/build/dagda-client"
CLIENT="$DAGDA/build/dagda-client"
echo "CLIENT=$CLIENT"
```

Start your counter on a socket in a fresh private directory
(terminal 1):

```sh
SOCK_DIR=$(mktemp -d /tmp/my-counter.XXXXXX)
SOCK=$SOCK_DIR/counter.sock
echo "SOCK=$SOCK"
./my-counter --socket "$SOCK"
```

Click **Increment** once in the window. In terminal 2 — a fresh
shell that needs nothing else — paste both printed assignments
(the `SOCK=...` line from terminal 1 and the `CLIENT=...` line
from the build step), then inspect the count — it reads `1`:

```sh
SOCK=/tmp/my-counter.AbCdEf/counter.sock   # paste your line
CLIENT=/path/to/dagda/build/dagda-client   # paste your line
"$CLIENT" "$SOCK" inspect counter.value
# {"ok":true,"elements":[{"id":1,"role":"counter.value","kind":"label","text":"1",...}]}
```

Now let the agent press the same button. Discover its ID by
role, invoke it, and inspect again — the count reads `2`:

```sh
"$CLIENT" "$SOCK" inspect counter.increment
# {"ok":true,"elements":[{"id":2,"role":"counter.increment","kind":"button","text":"Increment",...}]}
"$CLIENT" "$SOCK" invoke 2 activate
"$CLIENT" "$SOCK" inspect counter.value
# {"ok":true,"elements":[{"id":1,"role":"counter.value","kind":"label","text":"2",...}]}
```

Close the window when you are done; it removes its own socket
file, and `rmdir "$SOCK_DIR"` in terminal 1 cleans up.

## Where to go next

- The in-repo version of this app, with its acceptance test, is
  [examples/counter](../examples/counter/).
- A shared editable headline lives in
  [examples/shared-text](../examples/shared-text/), and the
  headless advertised-edit workflow in
  [examples/advertised-edit-app](../examples/advertised-edit-app/).
- For fixed-aspect canvas layouts, advertised edits, and IME
  text editing, see the examples under `examples/` and the
  framework packages under `dagda/` in the checkout.
