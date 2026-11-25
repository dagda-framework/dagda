package dagda

import "core:strings"
import "core:testing"

// Test app: object 1 holds text, object 2 holds a rectangle.
// The app owns both values, their revisions, and undo history,
// and enforces all document policy in its handler.
Test_Doc :: struct {
	title:        string,
	title_rev:    Revision,
	title_hist:   string,
	has_title_hist: bool,
	chart:        Rect,
	chart_rev:    Revision,
	chart_hist:   Rect,
	has_chart_hist: bool,
	calls:        int,
	edits:        []Advertised_Edit,
}

test_doc_edits := []Advertised_Edit{
	{object_id = 1, edit = "replace_text", argument = .Text},
	{object_id = 2, edit = "set_rect", argument = .Rect},
}

doc_init :: proc(doc: ^Test_Doc) {
	doc.title = strings.clone("Quarterly results")
	doc.chart = {x = 10, y = 20, width = 100, height = 50}
	doc.edits = test_doc_edits
}

doc_destroy :: proc(doc: ^Test_Doc) {
	delete(doc.title)
	delete(doc.title_hist)
	doc^ = {}
}

doc_handle :: proc(user_data: rawptr, target: Action_Target, edit: string, arg: Edit_Argument) -> Edit_Result {
	doc := (^Test_Doc)(user_data)
	doc.calls += 1
	switch target.id {
	case 1:
		if target.base_revision != doc.title_rev {
			return .Stale_Revision
		}
		if len(arg.text) == 0 {
			return .Not_Handled // app policy: no empty titles
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
		if arg.rect.width <= 0 || arg.rect.height <= 0 {
			return .Not_Handled // app policy: positive size only
		}
		doc.chart_hist = doc.chart
		doc.has_chart_hist = true
		doc.chart = arg.rect
		doc.chart_rev += 1
		return .Applied
	}
	return .Unknown_Object
}

doc_undo :: proc(doc: ^Test_Doc, id: Object_Id) -> bool {
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

@(test)
test_advertised_edits_discover_preview_commit :: proc(t: ^testing.T) {
	doc: Test_Doc
	doc_init(&doc)
	defer doc_destroy(&doc)

	// Discover each edit and its declared argument type.
	out: [2]Advertised_Edit
	written, total := edits_for(doc.edits, 1, out[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, out[0].edit, "replace_text")
	testing.expect_value(t, out[0].argument, Edit_Argument_Kind.Text)
	written, total = edits_for(doc.edits, 2, out[:])
	testing.expect_value(t, out[0].edit, "set_rect")
	testing.expect_value(t, out[0].argument, Edit_Argument_Kind.Rect)

	// Preview without mutation; the preview owns its text copy.
	buf := []u8{'D', 'r', 'a', 'f', 't'}
	preview, result := preview_edit(doc.edits, {id = 1, base_revision = 0}, "replace_text", argument_text(string(buf)))
	testing.expect_value(t, result, Edit_Result.Applied)
	buf[0] = 'X'
	testing.expect_value(t, preview.argument.text, "Draft")
	preview_destroy(&preview)
	testing.expect_value(t, doc.title, "Quarterly results")
	testing.expect_value(t, doc.calls, 0)

	// Commit both edits through the app handler.
	testing.expect_value(t, commit_edit(doc.edits, {id = 1, base_revision = 0}, "replace_text", argument_text("Revenue grew"), doc_handle, &doc), Edit_Result.Applied)
	testing.expect_value(t, doc.title, "Revenue grew")
	testing.expect_value(t, doc.title_rev, Revision(1))
	new_rect := Rect{x = 72, y = 240, width = 360, height = 180}
	testing.expect_value(t, commit_edit(doc.edits, {id = 2, base_revision = 0}, "set_rect", argument_rect(new_rect), doc_handle, &doc), Edit_Result.Applied)
	testing.expect_value(t, doc.chart, new_rect)
	testing.expect_value(t, doc.chart_rev, Revision(1))

	// One app-owned undo per object restores the prior values.
	testing.expect(t, doc_undo(&doc, 1))
	testing.expect_value(t, doc.title, "Quarterly results")
	testing.expect(t, doc_undo(&doc, 2))
	testing.expect_value(t, doc.chart, Rect{x = 10, y = 20, width = 100, height = 50})
}

@(test)
test_advertised_edits_rejections_untouched :: proc(t: ^testing.T) {
	doc: Test_Doc
	doc_init(&doc)
	defer doc_destroy(&doc)

	// Wrong arguments never reach the handler.
	testing.expect_value(t, commit_edit(doc.edits, {id = 1, base_revision = 0}, "replace_text", argument_rect({width = 1, height = 1}), doc_handle, &doc), Edit_Result.Wrong_Argument)
	testing.expect_value(t, commit_edit(doc.edits, {id = 2, base_revision = 0}, "set_rect", argument_text("wide"), doc_handle, &doc), Edit_Result.Wrong_Argument)
	testing.expect_value(t, doc.calls, 0)

	// Unknown object and unknown edit are distinct.
	testing.expect_value(t, commit_edit(doc.edits, {id = 99, base_revision = 0}, "replace_text", argument_text("X"), doc_handle, &doc), Edit_Result.Unknown_Object)
	testing.expect_value(t, commit_edit(doc.edits, {id = 1, base_revision = 0}, "delete", argument_none(), doc_handle, &doc), Edit_Result.Unknown_Edit)

	// A stale revision reaches the handler's policy and the
	// state (including undo history) stays untouched.
	testing.expect_value(t, commit_edit(doc.edits, {id = 1, base_revision = 7}, "replace_text", argument_text("Late"), doc_handle, &doc), Edit_Result.Stale_Revision)
	testing.expect_value(t, doc.title, "Quarterly results")
	testing.expect_value(t, doc.title_rev, Revision(0))
	testing.expect(t, !doc.has_title_hist)
	testing.expect(t, !doc_undo(&doc, 1))
}
