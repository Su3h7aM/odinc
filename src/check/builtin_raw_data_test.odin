package check

import "core:testing"

@(test)
raw_data_accepts_dynamic_arrays_and_preserves_element_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
direct :: proc(array: [dynamic]u8) -> [^]u8 { _ = cap(array)*size_of(u8); return raw_data(array) }
bad :: proc(array: int) -> [^]u8 { return raw_data(array) }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "direct")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
	rejected, rejected_ok := check_procedure_source(t, source, procedure_name = "bad")
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}
