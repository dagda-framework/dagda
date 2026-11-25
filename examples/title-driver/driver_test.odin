package title_driver

import "core:testing"
import title_model "dagda:examples/title-model"

// The five Round 3A wire fixtures, in sequence on one fresh model.
FIXTURES: [5][2]string = {
	{"{\"op\":\"inspect\",\"role\":\"slide.title\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\",\"role\":\"slide.title\"}"},
	{"{\"op\":\"preview\",\"id\":1,\"base_revision\":0,\"text\":\"Revenue grew 12%\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Revenue grew 12%\"}"},
	{"{\"op\":\"commit\",\"id\":1,\"base_revision\":0,\"text\":\"Revenue grew 12%\"}", "{\"ok\":true,\"id\":1,\"revision\":1,\"text\":\"Revenue grew 12%\"}"},
	{"{\"op\":\"commit\",\"id\":1,\"base_revision\":0,\"text\":\"Late edit\"}", "{\"ok\":false,\"error\":\"Stale_Revision\",\"revision\":1}"},
	{"{\"op\":\"undo\",\"id\":1,\"base_revision\":1}", "{\"ok\":true,\"id\":1,\"revision\":2,\"text\":\"Quarterly results\",\"changed\":true}"},
}

fresh_model :: proc(t: ^testing.T) -> title_model.Model {
	model: title_model.Model
	err := title_model.init(&model, {id = 1, role = "slide.title"}, "Quarterly results")
	testing.expect_value(t, err, title_model.Error.None)
	return model
}

expect_reply :: proc(t: ^testing.T, model: ^title_model.Model, request, expected: string) {
	reply := dispatch(model, request)
	defer delete(reply)
	testing.expect_value(t, reply, expected)
}

@(test)
test_wire_fixtures :: proc(t: ^testing.T) {
	model := fresh_model(t)
	defer title_model.destroy(&model)
	for fixture in FIXTURES {
		expect_reply(t, &model, fixture[0], fixture[1])
	}
}

@(test)
test_preview_does_not_mutate :: proc(t: ^testing.T) {
	model := fresh_model(t)
	defer title_model.destroy(&model)
	expect_reply(t, &model, "{\"op\":\"preview\",\"id\":1,\"base_revision\":0,\"text\":\"Draft\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Draft\"}")
	expect_reply(t, &model, "{\"op\":\"inspect\",\"role\":\"slide.title\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\",\"role\":\"slide.title\"}")
}

@(test)
test_noop_empty_undo_missing_and_malformed :: proc(t: ^testing.T) {
	model := fresh_model(t)
	defer title_model.destroy(&model)
	// Empty undo reports no change at revision 0.
	expect_reply(t, &model, "{\"op\":\"undo\",\"id\":1,\"base_revision\":0}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\",\"changed\":false}")
	// No-op commit preserves revision.
	expect_reply(t, &model, "{\"op\":\"commit\",\"id\":1,\"base_revision\":0,\"text\":\"Quarterly results\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\"}")
	// Missing role and missing ID keep their distinct errors.
	expect_reply(t, &model, "{\"op\":\"inspect\",\"role\":\"slide.missing\"}", "{\"ok\":false,\"error\":\"Unknown_Role\"}")
	expect_reply(t, &model, "{\"op\":\"commit\",\"id\":99,\"base_revision\":0,\"text\":\"X\"}", "{\"ok\":false,\"error\":\"Unknown_Object\"}")
	expect_reply(t, &model, "{\"op\":\"undo\",\"id\":99,\"base_revision\":0}", "{\"ok\":false,\"error\":\"Unknown_Object\"}")
	// Malformed requests are structured and leave the document usable.
	expect_reply(t, &model, "not json", "{\"ok\":false,\"error\":\"Malformed_Request\"}")
	expect_reply(t, &model, "{\"op\":\"bogus\"}", "{\"ok\":false,\"error\":\"Unknown_Operation\"}")
	expect_reply(t, &model, "{\"op\":\"inspect\",\"role\":\"slide.title\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\",\"role\":\"slide.title\"}")
}

@(test)
test_blank_trailing_and_utf8_rejected_before_dispatch :: proc(t: ^testing.T) {
	model := fresh_model(t)
	defer title_model.destroy(&model)
	bad_lines := []string{"", "   ", "{\"op\":\"inspect\",\"role\":\"slide.title\"} extra", "{\"op\":\"inspect\",\"role\":\"slide.title\"} {}", "{\"op\":\"inspect\",\"role\":\"slide.title\"}\xff", "[1,2]", "{\"op\":\"commit\",\"id\":1,\"base_revision\":0,\"text\":\"Bad\"} trailing"}
	for line in bad_lines {
		expect_reply(t, &model, line, "{\"ok\":false,\"error\":\"Malformed_Request\"}")
	}
	// None of the rejected lines mutated the document.
	expect_reply(t, &model, "{\"op\":\"inspect\",\"role\":\"slide.title\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\",\"role\":\"slide.title\"}")
	// Out-of-range and non-integer IDs are malformed on the wire too.
	expect_reply(t, &model, "{\"op\":\"commit\",\"id\":-1,\"base_revision\":0,\"text\":\"X\"}", "{\"ok\":false,\"error\":\"Malformed_Request\"}")
	expect_reply(t, &model, "{\"op\":\"commit\",\"id\":1.5,\"base_revision\":0,\"text\":\"X\"}", "{\"ok\":false,\"error\":\"Malformed_Request\"}")
}

@(test)
test_id_fields_signed_range_from_raw_tokens :: proc(t: ^testing.T) {
	model := fresh_model(t)
	defer title_model.destroy(&model)
	// Signed maximum is in range for both fields: the requests are
	// dispatched and answered with the model's own distinctions.
	expect_reply(t, &model, "{\"op\":\"commit\",\"id\":9223372036854775807,\"base_revision\":0,\"text\":\"X\"}", "{\"ok\":false,\"error\":\"Unknown_Object\"}")
	expect_reply(t, &model, "{\"op\":\"commit\",\"id\":1,\"base_revision\":9223372036854775807,\"text\":\"X\"}", "{\"ok\":false,\"error\":\"Stale_Revision\",\"revision\":0}")
	// Beyond the maximum, including a huge decimal that a narrowing
	// conversion would turn into a small positive integer, is
	// malformed for either field and leaves the document unchanged.
	huge := []string{
		"{\"op\":\"commit\",\"id\":9223372036854775808,\"base_revision\":0,\"text\":\"X\"}",
		"{\"op\":\"commit\",\"id\":1,\"base_revision\":9223372036854775808,\"text\":\"X\"}",
		"{\"op\":\"commit\",\"id\":18446744073709551617,\"base_revision\":0,\"text\":\"X\"}",
		"{\"op\":\"commit\",\"id\":1,\"base_revision\":18446744073709551617,\"text\":\"X\"}",
		"{\"op\":\"undo\",\"id\":99999999999999999999999999,\"base_revision\":0}",
		"{\"op\":\"undo\",\"id\":1,\"base_revision\":99999999999999999999999999}",
	}
	for line in huge {
		expect_reply(t, &model, line, "{\"ok\":false,\"error\":\"Malformed_Request\"}")
	}
	expect_reply(t, &model, "{\"op\":\"inspect\",\"role\":\"slide.title\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\",\"role\":\"slide.title\"}")
}

@(test)
test_escaped_field_names_match_literal :: proc(t: ^testing.T) {
	model := fresh_model(t)
	defer title_model.destroy(&model)
	// \x5c is a backslash, so the escaped lines carry the field
	// names as \uXXXX spellings, decoded by the JSON library.
	literal_preview := "{\"op\":\"preview\",\"id\":1,\"base_revision\":0,\"text\":\"Draft\"}"
	escaped_preview := "{\"op\":\"preview\",\"\x5cu0069d\":1,\"base_\x5cu0072evision\":0,\"text\":\"Draft\"}"
	preview_reply := "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Draft\"}"
	expect_reply(t, &model, literal_preview, preview_reply)
	expect_reply(t, &model, escaped_preview, preview_reply)

	literal_bad := "{\"op\":\"commit\",\"id\":9223372036854775808,\"base_revision\":0,\"text\":\"X\"}"
	escaped_bad_id := "{\"op\":\"commit\",\"\x5cu0069d\":9223372036854775808,\"base_revision\":0,\"text\":\"X\"}"
	escaped_bad_rev := "{\"op\":\"commit\",\"id\":1,\"base_\x5cu0072evision\":9223372036854775808,\"text\":\"X\"}"
	bad := []string{literal_bad, escaped_bad_id, escaped_bad_rev}
	for line in bad {
		expect_reply(t, &model, line, "{\"ok\":false,\"error\":\"Malformed_Request\"}")
	}
	// Rejected requests preserved title and revision.
	expect_reply(t, &model, "{\"op\":\"inspect\",\"role\":\"slide.title\"}", "{\"ok\":true,\"id\":1,\"revision\":0,\"text\":\"Quarterly results\",\"role\":\"slide.title\"}")
}
