# Dagda

Dagda is an experimental native UI framework for Odin, designed for applications that people and agents can operate together. In a slide editor, the headline on the canvas and the title in the outline represent the same object. The goal is for a person to edit it in either view, for an agent to propose a rename while the person works, and for either of them to undo the change.

Today you can run the headless core on Linux. It demonstrates the part both interfaces will share: an Odin application defines an edit, previews its effect, and checks whether the document has changed before applying it.

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

The application defines what it means to rename a title. Dagda supplies the target, which carries an object ID and the document revision the caller saw.

```odin
Rename :: struct {
	target: dagda.Action_Target,
	text:   string,
}
```

The same procedure runs on a copy of the slide for preview and on the original for commit.

```odin
apply :: proc(slide: ^Slide, action: Rename) -> dagda.Action_Error {
	if err := dagda.check_target(action.target, slide.title.object, slide.revision); err != .None {
		return err
	}
	if action.text != slide.title.text {
		slide.title.text = action.text
		slide.revision += 1
	}
	return .None
}
```

A second proposal can still name the right title and be out of date. Checking the revision before writing gives the caller a chance to read the new headline and reconsider its edit. [Full example](examples/shared-title/main.odin) · [Dagda core](dagda/core.odin)

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
