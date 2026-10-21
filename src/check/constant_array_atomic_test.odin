package check

import "core:testing"

@(test)
constant_array_elements_keep_field_constants :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Kind :: enum { A = 3, B }
Record :: struct { value: int, kind: Kind, flags: bit_set[Kind], slots: [2]int }
TABLE :: [Kind]Record{.A = {value = 2, kind = .B, flags = {.A}, slots = {7, 9}}, .B = {value = 4}}
ARRAY :: [2]Record{{value = 2}, {value = 4}}
main :: proc() {
 #assert(Record{value = 2}.value == 2)
 #assert(Kind.A != Kind.B)
 #assert(ARRAY[0].value == 2)
 #assert(TABLE[.A].value == 2 && TABLE[.B].value == 4)
 #assert(TABLE[.A].kind == .B)
 #assert(TABLE[.A].slots[1] == 9)
 #assert(Kind.A in TABLE[.A].flags)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
atomic_lock_free_query_is_constant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Flag :: enum { A, B }
Small :: struct { value: int }
Large :: struct { values: [3]int }
main :: proc() {
 #assert(atomic_type_is_lock_free(i8))
 #assert(atomic_type_is_lock_free(int))
 #assert(atomic_type_is_lock_free(bool))
 #assert(atomic_type_is_lock_free(f64))
 #assert(atomic_type_is_lock_free(^int))
 #assert(atomic_type_is_lock_free(Flag))
 #assert(atomic_type_is_lock_free(bit_set[Flag]))
 #assert(atomic_type_is_lock_free(Small))
 #assert(!atomic_type_is_lock_free(i128))
 #assert(!atomic_type_is_lock_free(Large))
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0, intrinsic_names = {"atomic_type_is_lock_free"})
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}
