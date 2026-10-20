package main

import "base:intrinsics"

Named_Integer :: distinct i16
Index :: enum i16 {
	First,
	Second,
}
Record :: struct {
	field: intrinsics.type_elem_type([2]i16),
}
Box :: struct($T: typeid) {
	value: intrinsics.type_elem_type(T),
}
element_type :: intrinsics.type_elem_type
global_value: intrinsics.type_bit_set_underlying_type(bit_set[Index;u16]) = 17

sum :: proc(left: intrinsics.type_base_type(Named_Integer), right: intrinsics.type_core_type(Index)) -> intrinsics.type_field_type(Record, "field") {
	return left + right
}

main :: proc() {
	item: element_type([2]i16) = 11
	box: Box([2]i32)
	box.value = 13
	record := Record {
		field = 19,
	}
	values: [2]intrinsics.type_elem_type([3]i16)
	values[1] = 21
	view: []intrinsics.type_elem_type([3]i16) = values[:]
	pointer := (^intrinsics.type_elem_type([3]i16))(&values[1])
	result := int(sum(7, 9)) + int(item) + int(box.value) + int(global_value) + int(record.field) + int(pointer^)
	if len(view) != 2 || view[1] != 21 { result = 99 }
	intrinsics.syscall(60, uintptr(result))
}
