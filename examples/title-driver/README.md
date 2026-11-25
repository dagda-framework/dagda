# Local title driver

A Linux headless host and terminal client for one editable slide
title, speaking newline-delimited UTF-8 JSON over a Unix-domain
stream socket. The host owns the only model instance and keeps it
across separate client invocations; the dispatcher
(`driver.odin`) is transport-independent and can be called with
any `examples/title-model` instance.

## Protocol

One JSON object per line. A fresh host starts with title `#1`,
role `slide.title`, revision `0`, text `"Quarterly results"`.

| Request | Fields |
| --- | --- |
| `{"op":"inspect","role":"slide.title"}` | discover by role |
| `{"op":"preview","id":1,"base_revision":0,"text":"…"}` | preview by ID |
| `{"op":"commit","id":1,"base_revision":0,"text":"…"}` | commit by ID |
| `{"op":"undo","id":1,"base_revision":1}` | undo by ID |

Success replies are `{"ok":true,"id":…,"revision":…,"text":…}`;
inspect also returns `"role"`, undo also returns `"changed"`.
Failures are `{"ok":false,"error":"Name"}`, with the current
`"revision"` added for stale requests. Model error distinctions
(`Unknown_Object`, `Stale_Revision`, `Invalid_Text`,
`Alloc_Failed`) are preserved; malformed lines return
`Malformed_Request` and leave the document usable.

## Run

From the repository root:

```sh
bash scripts/setup-odin.sh   # once, if the pinned compiler is missing
./scripts/odin.sh build examples/title-driver-host -collection:dagda=. -out:/tmp/title-host
./scripts/odin.sh build examples/title-driver-client -collection:dagda=. -out:/tmp/title-client

SOCK_DIR=$(mktemp -d /tmp/dagda-title.XXXXXX)   # fresh private directory
SOCK=$SOCK_DIR/title.sock
/tmp/title-host $SOCK &   # prints: Listening /tmp/dagda-title.XXXXXX/title.sock
/tmp/title-client $SOCK inspect slide.title
/tmp/title-client $SOCK preview 1 0 "Revenue grew 12%"
/tmp/title-client $SOCK commit 1 0 "Revenue grew 12%"
/tmp/title-client $SOCK undo 1 1
/tmp/title-client $SOCK inspect slide.title
kill %1   # the host removes its own socket file on SIGINT/SIGTERM
rmdir $SOCK_DIR
```

The client prints the single JSON reply and exits `0` when
`ok` is true, `1` otherwise. The socket path is always explicit;
the host refuses to start if the path already exists and only
ever removes the endpoint it created: it records the bound
entry's identity (device and inode, via a no-follow lookup) at
bind time and unlinks the path at shutdown only if that same
entry is still there, so a replacement file or symlink is
preserved. This assumes the socket directory itself is owned
by the user running the host and is not writable by other
local users who could swap entries mid-run; use a private
directory such as a per-user temporary directory.

## Tests

```sh
./scripts/odin.sh test examples/title-driver -collection:dagda=.
python3 examples/title-driver/tests/e2e_test.py
```

The end-to-end test builds both binaries, runs them as real
processes against a temporary per-test socket directory, covers
the five wire fixtures plus no-op commit, empty undo, missing
role/ID, split and coalesced stream reads, and malformed input.
