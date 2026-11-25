package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "dagda:dagda"
import driver "dagda:dagda/driver"

// Headless test app for advertised edits. The app owns the text
// and rectangle values, their revisions, undo history, and all
// document policy; Dagda only carries the declarations.

Doc :: struct {
	title:         string,
	title_rev:     dagda.Revision,
	title_hist:    string,
	has_title_hist: bool,
	chart:         dagda.Rect,
	chart_rev:     dagda.Revision,
	chart_hist:    dagda.Rect,
	has_chart_hist: bool,
}

doc_edits := []dagda.Advertised_Edit{
	{object_id = 1, edit = "replace_text", argument = .Text},
	{object_id = 2, edit = "set_rect", argument = .Rect},
	{object_id = 2, edit = "reset_rect", argument = .None},
}

doc_handle :: proc(user_data: rawptr, target: dagda.Action_Target, edit: string, arg: dagda.Edit_Argument) -> dagda.Edit_Result {
	doc := (^Doc)(user_data)
	switch target.id {
	case 1:
		if target.base_revision != doc.title_rev {
			return .Stale_Revision
		}
		if len(arg.text) == 0 {
			return .Not_Handled
		}
		delete(doc.title_hist)
		doc.title_hist = doc.title
		doc.has_title_hist = true
		doc.title = strings.clone(arg.text)
		doc.title_rev += 1
		return .Applied
	case 2:
		if target.base_revision != doc.chart_rev {
			return .Stale_Revision
		}
		if edit == "reset_rect" {
			doc.chart_hist = doc.chart
			doc.has_chart_hist = true
			doc.chart = {x = 10, y = 20, width = 100, height = 50}
			doc.chart_rev += 1
			return .Applied
		}
		if arg.rect.width <= 0 || arg.rect.height <= 0 {
			return .Not_Handled
		}
		doc.chart_hist = doc.chart
		doc.has_chart_hist = true
		doc.chart = arg.rect
		doc.chart_rev += 1
		return .Applied
	}
	return .Unknown_Object
}

doc_revision :: proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	doc := (^Doc)(user_data)
	switch id {
	case 1:
		return doc.title_rev, true
	case 2:
		return doc.chart_rev, true
	}
	return 0, false
}

doc_undo :: proc(doc: ^Doc, id: dagda.Object_Id) -> bool {
	switch id {
	case 1:
		if !doc.has_title_hist {
			return false
		}
		delete(doc.title)
		doc.title = doc.title_hist
		doc.title_hist = ""
		doc.has_title_hist = false
		doc.title_rev += 1
		return true
	case 2:
		if !doc.has_chart_hist {
			return false
		}
		doc.chart = doc.chart_hist
		doc.has_chart_hist = false
		doc.chart_rev += 1
		return true
	}
	return false
}

Host :: struct {
	doc:        Doc,
	frame:      dagda.Frame,
	elements:   [2]dagda.Element,
	chart_text: string,
	chart_buf:  [96]u8,
}

host_rebuild :: proc(ctx: rawptr) -> bool {
	host := (^Host)(ctx)
	dagda.frame_destroy(&host.frame)
	chart := fmt.bprintf(host.chart_buf[:], "%g,%g,%g,%g", host.doc.chart.x, host.doc.chart.y, host.doc.chart.width, host.doc.chart.height)
	delete(host.chart_text)
	host.chart_text = strings.clone(chart)
	host.elements = {
		{info = {id = 1, role = "doc.title"}, kind = .Label, text = host.doc.title},
		{info = {id = 2, role = "doc.chart"}, kind = .Label, text = host.chart_text},
	}
	frame, ok := dagda.resolve({elements = host.elements[:]}, {width = 360, height = 180})
	if !ok {
		return false
	}
	host.frame = frame
	return true
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: edit-test-app <socket-path>")
		os.exit(2)
	}
	host: Host
	host.doc.title = strings.clone("Quarterly results")
	host.doc.chart = {x = 10, y = 20, width = 100, height = 50}
	defer {
		delete(host.doc.title)
		delete(host.doc.title_hist)
		delete(host.chart_text)
		dagda.frame_destroy(&host.frame)
	}
	if !host_rebuild(&host) {
		fmt.eprintln("could not build frame")
		os.exit(1)
	}

	server: driver.Server
	if !driver.server_start(&server, os.args[1]) {
		os.exit(1)
	}
	defer driver.server_stop(&server)

	source := driver.Edit_Source{edits = doc_edits, handler = doc_handle, user_data = &host.doc, revision_of = doc_revision}

	control: [dynamic]u8
	defer delete(control)
	running := true
	for running {
		_, failed := driver.server_poll_edits(&server, &host.frame, nil, nil, source, &host, host_rebuild)
		if failed {
			fmt.eprintln("frame rebuild failed")
			os.exit(1)
		}
		// Control stdin: "undo 1", "undo 2", "quit", each acked.
		pfd := posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}}
		if posix.poll(&pfd, 1, 10) > 0 {
			tmp: [256]u8
			n := posix.read(posix.STDIN_FILENO, raw_data(tmp[:]), 256)
			if n > 0 {
				append(&control, ..tmp[:int(n)])
				for {
					nl := -1
					for j in 0 ..< len(control) {
						if control[j] == '\n' {
							nl = j
							break
						}
					}
					if nl < 0 {
						break
					}
					line := string(control[:nl])
					// Process the line before compacting the
					// buffer: line borrows the bytes that the
					// compaction would overwrite.
					if line == "quit" {
						fmt.println("CONTROL_OK quit")
						running = false
					} else if line == "undo 1" || line == "undo 2" {
						id := dagda.Object_Id(line[len(line) - 1] - '0')
						undone := doc_undo(&host.doc, id)
						_ = host_rebuild(&host)
						rev, _ := doc_revision(&host.doc, id)
						fmt.printf("CONTROL_OK undo id=%d undone=%v revision=%d\n", id, undone, rev)
					}
					_ = os.flush(os.stdout)
					remaining := len(control) - (nl + 1)
					if remaining > 0 {
						copy(control[:remaining], control[nl + 1:])
					}
					resize(&control, remaining)
					if !running {
						break
					}
				}
			}
		}
	}
}
