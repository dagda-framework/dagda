# Dagda

Dagda is an experimental native UI framework for Odin, designed for applications that people and agents can operate together. In a slide editor, the headline on the canvas and the title in the outline represent the same object. The goal is for a person to edit it in either view, for an agent to propose a rename while the person works, and for either of them to undo the change.

Today you can run the headless core on Linux. It demonstrates the part both interfaces will share: a title model that owns its text, previews a proposed edit without changing the document, and checks the document revision before applying it.

## Run the example

From the repository root on Linux x86-64, run the following commands. The setup script installs the pinned Odin compiler and requires Python 3, curl, tar, and sha256sum.

```sh
bash scripts/setup-odin.sh
./scripts/odin.sh run examples/shared-title -collection:dagda=.
```

The example starts with a known title, prints its role and ID, and tries two edits based on revision zero.

```text
Inspect  slide.title #1 at revision 0: Quarterly results
Preview  Revenue grew 12% (document still reads "Quarterly results")
Commit   revision 1: Revenue grew 12%
Retry    Stale_Revision (document still reads "Revenue grew 12%")
```

## Read the Odin

The example discovers the title by its semantic role. Dagda supplies the target, which carries the discovered object ID and the document revision the caller saw. The title model owns both strings.

```odin
snap := title_model.snapshot(&model)
objects := [1]dagda.Object_Info{snap.object}
ids: [1]dagda.Object_Id
written, total := dagda.find_by_role(objects[:], "slide.title", ids[:])
if written != 1 || total != 1 {
	panic("Expected exactly one slide.title object")
}

target := dagda.Action_Target{id = ids[0], base_revision = snap.revision}
```

A preview clones the proposed text into storage the preview itself owns, so the document still reads the old title and discarding the preview changes nothing. Commit checks the ID and revision before installing its own copy of the new text.

```odin
p, preview_err := title_model.preview(&model, target, "Revenue grew 12%")
if preview_err != .None {
	panic("Example preview failed")
}
defer title_model.preview_destroy(&p)
fmt.printf("Preview  %s (document still reads %q)\n", p.text, title_model.snapshot(&model).text)

if err := title_model.commit(&model, target, "Revenue grew 12%"); err != .None {
	panic("Example commit failed")
}
```

In the final line of the demo, retrying the original target returns `Stale_Revision`. Checking the revision before writing gives the caller a chance to read the new headline and reconsider its edit. [Full example](examples/shared-title/main.odin) · [Title model](examples/title-model/title_model.odin) · [Dagda core](dagda/core.odin)

## From the document to the window

The planned desktop API keeps an object's meaning alongside its geometry. A chart can expose its series and layout constraints. A view can report where the legend landed and whether a label was clipped. An agent editing the chart could inspect the series, invoke a typed action, and check a rendered preview. An agent testing the UI could reach the same action through keyboard input or a drag. Each window would keep its own focus, selection, and text composition.

This design draws on GPUI's custom native views, focus handling, and typed actions, and on Exact's driver for inspecting and exercising a running app. [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) · [Exact’s agent loop](https://github.com/expo/exact#the-agent-loop)

## First desktop milestone

The first desktop target is Linux with SDL3. The window, local driver, and shared undo history are planned. The milestone is one interaction across a terminal and a window:

1. Open a slide and place the caret in its title.
2. From the terminal, discover the title by role and preview a rename. The window still shows the original.
3. Commit the rename. The window displays the new title and retains keyboard focus.
4. Press Undo in the window. The terminal receives the change and can read the restored title.

Repeat with a human edit between preview and commit. The terminal should report a stale revision and the person's edit should survive. macOS and Windows are later native targets.
