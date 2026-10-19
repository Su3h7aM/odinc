package check

import "core:testing"

@(test)
length_of_dynamic_array_checks_through_pointer_and_value :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Builder :: struct { buf: [dynamic]byte }
through_pointer :: proc "contextless" (b: ^Builder) -> int { return len(b.buf) }
through_value :: proc "contextless" (values: [dynamic]u8) -> int { return len(values) }
through_cstrings :: proc(text: cstring, wide: cstring16) -> int { return len(text) + len(wide) }
Sparse :: enum { A = 2, B = 5, C = 11 }
constant_lengths :: proc() { #assert(len(Sparse) == 3); #assert(len(#sparse[Sparse]int) == 10) }
`,
	)
	for name in ([?]string{"through_pointer", "through_value", "through_cstrings", "constant_lengths"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name)
		if ok { testing.expect(t, procedure.body_state == .Complete) }
	}
}

@(test)
capacity_of_dynamic_arrays_and_maps_checks_through_pointers :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
array :: proc(values: [dynamic]u8) -> int { return cap(values) }
map_value :: proc(values: map[string]int) -> int { return cap(values) }
map_pointer :: proc(values: ^map[string]int) -> int { return len(values) }
bad :: proc(values: []u8) -> int { return cap(values) }
`,
	)
	for name in ([?]string{"array", "map_value", "map_pointer"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name)
		if ok { testing.expect(t, procedure.body_state == .Complete) }
	}
	procedure, ok := check_procedure_source(t, source, procedure_name = "bad")
	if ok { testing.expect(t, procedure.body_state == .Invalid) }
}
