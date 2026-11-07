package dagda_db

import "core:testing"

@(test)
structured_errors_and_scalar_mapping :: proc(t: ^testing.T) {
    for entry in ([]struct {code: string, kind: Failure_Kind}{
        {"23505", .Constraint}, {"40001", .Serialization}, {"40P01", .Deadlock},
        {"57014", .Canceled}, {"22012", .Query},
    }) {
        error := classify_state(entry.code)
        testing.expect_value(t, error.kind, entry.kind)
        testing.expect_value(t, state_code(&error), entry.code)
    }
    integer: i8
    testing.expect(t, map_cell({data="127"}, 20, type_info_of(i8), &integer))
    testing.expect_value(t, integer, 127)
    testing.expect(t, !map_cell({data="128"}, 20, type_info_of(i8), &integer))
    testing.expect(t, !map_cell({data="1"}, 25, type_info_of(i8), &integer))
    unsigned: u64
    testing.expect(t, !map_cell({data="-1"}, 20, type_info_of(u64), &unsigned))
    optional: Nullable(i64)
    testing.expect(t, map_cell({is_null=true}, 20, type_info_of(Nullable(i64)), &optional))
    testing.expect(t, !optional.valid)
    testing.expect(t, map_cell({data="0"}, 20, type_info_of(Nullable(i64)), &optional))
    testing.expect(t, optional.valid && optional.value == 0)
    testing.expect(t, !map_cell({is_null=true}, 20, type_info_of(i8), &integer))
}

@(test)
row_mapping_is_atomic_and_matches_names :: proc(t: ^testing.T) {
    rows := Rows{count=1}
    defer delete(rows.columns)
    defer delete(rows.cells)
    append(&rows.columns, Column{"display_name",25}, Column{"id",20})
    append(&rows.cells, Cell{data="example"}, Cell{data="9"})
    DTO :: struct { id: i32, name: string `db:"display_name"` }
    destination := DTO{42,"unchanged"}
    testing.expect_value(t, scan(&rows, 0, &destination).kind, .None)
    testing.expect_value(t, destination.id, 9)
    testing.expect_value(t, destination.name, "example")
    rows.cells[1].data = "2147483648"
    testing.expect_value(t, scan(&rows, 0, &destination).kind, .Mapping)
    testing.expect_value(t, destination.id, 9)
    testing.expect(t, scan(&rows, 1, &destination).kind == .Mapping)
    rows.columns[1].name = "display_name"
    testing.expect_value(t, scan(&rows, 0, &destination).kind, .Mapping)
}
