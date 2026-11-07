package dagda_db

import "core:reflect"
import "core:strconv"

// Exact PostgreSQL text representations. Decimal never passes through float.
UUID :: distinct string
Timestamp :: distinct string // timestamptz, preserving the server's offset/precision
Decimal :: distinct string
JSON :: distinct string
Nullable :: struct($T: typeid) { value: T, valid: bool }

// Explicit struct mapping by column name (or `db:"column"` tag). The destination
// changes only on full success. Strings and byte slices borrow the owned Rows.
scan :: proc(rows: ^Rows, index: int, destination: ^$T) -> Failure {
    if rows == nil || destination == nil || index < 0 || index >= rows.count { return {kind=.Mapping} }
    if rows.count > MAX_ROWS || len(rows.columns) > MAX_COLUMNS || len(rows.cells) != rows.count * len(rows.columns) { return {kind=.Mapping} }
    info := reflect.type_info_base(type_info_of(T))
    if _, ok := info.variant.(reflect.Type_Info_Struct); !ok { return {kind=.Mapping} }
    fields := reflect.struct_fields_zipped(T)
    if len(fields) != len(rows.columns) { return {kind=.Mapping} }
    value: T
    used: [MAX_COLUMNS]bool
    for field in fields {
        if field.is_using { return {kind=.Mapping} }
        name := field.name
        if tag, ok := reflect.struct_tag_lookup(field.tag, "db"); ok { name = tag }
        column := -1
        for entry, i in rows.columns {
            if entry.name == name {
                if column >= 0 { return {kind=.Mapping} }
                column = i
            }
        }
        if column < 0 || used[column] { return {kind=.Mapping} }
        used[column] = true
        pointer := rawptr(uintptr(&value) + field.offset)
        if !map_cell(rows.cells[index * len(rows.columns) + column], rows.columns[column].oid, field.type, pointer) { return {kind=.Mapping} }
    }
    destination^ = value
    return {}
}
map_cell :: proc(cell: Cell, oid: u32, info: ^reflect.Type_Info, destination: rawptr) -> bool {
    base := reflect.type_info_base(info)
    if _, ok := base.variant.(reflect.Type_Info_Struct); ok {
        fields := reflect.struct_fields_zipped(info.id)
        // The Nullable shape is deliberately structural and supports aliases.
        if len(fields) != 2 || fields[0].name != "value" || fields[1].name != "valid" || fields[1].type.id != bool { return false }
        (cast(^bool)rawptr(uintptr(destination) + fields[1].offset))^ = !cell.is_null
        if cell.is_null { return true }
        return map_cell(cell, oid, fields[0].type, rawptr(uintptr(destination) + fields[0].offset))
    }
    if cell.is_null { return false }
    if info.id == UUID { if oid != 2950 { return false }; (cast(^UUID)destination)^ = UUID(cell.data); return true }
    if info.id == Timestamp { if oid != 1184 { return false }; (cast(^Timestamp)destination)^ = Timestamp(cell.data); return true }
    if info.id == Decimal { if oid != 1700 { return false }; (cast(^Decimal)destination)^ = Decimal(cell.data); return true }
    if info.id == JSON { if oid != 114 && oid != 3802 { return false }; (cast(^JSON)destination)^ = JSON(cell.data); return true }
    #partial switch kind in base.variant {
    case reflect.Type_Info_String:
        if info.id == cstring || !(oid == 25 || oid == 1043 || oid == 1042 || oid == 19) { return false }
        (cast(^string)destination)^ = cell.data
        return true
    case reflect.Type_Info_Boolean:
        if oid != 16 || (cell.data != "t" && cell.data != "f") { return false }
        (cast(^bool)destination)^ = cell.data == "t"
        return true
    case reflect.Type_Info_Integer:
        if !(oid == 20 || oid == 21 || oid == 23) || base.size > 8 { return false }
        value, ok := strconv.parse_i64(cell.data)
        if !ok { return false }
        bits := uint(base.size * 8)
        if kind.signed {
            if bits < 64 && (value < -(i64(1) << (bits-1)) || value >= (i64(1) << (bits-1))) { return false }
            switch base.size {
            case 1: (cast(^i8)destination)^ = i8(value)
            case 2: (cast(^i16)destination)^ = i16(value)
            case 4: (cast(^i32)destination)^ = i32(value)
            case 8: (cast(^i64)destination)^ = value
            }
        } else {
            if value < 0 || (bits < 64 && u64(value) >= (u64(1) << bits)) { return false }
            switch base.size {
            case 1: (cast(^u8)destination)^ = u8(value)
            case 2: (cast(^u16)destination)^ = u16(value)
            case 4: (cast(^u32)destination)^ = u32(value)
            case 8: (cast(^u64)destination)^ = u64(value)
            }
        }
        return true
    case reflect.Type_Info_Slice:
        if info.id != []byte || oid != 17 { return false }
        (cast(^[]byte)destination)^ = transmute([]byte)cell.data
        return true
    }
    return false
}
