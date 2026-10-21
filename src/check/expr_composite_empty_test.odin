package check

import "core:testing"

@(test)
empty_literal_of_scalar_result_type_is_zero :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
count_zero :: proc(a: int) -> (count: int) {
	if a == 0 { return {} }
	return a
}
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "count_zero")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
empty_literal_of_pointer_like_type_is_nil :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Nil :: distinct rawptr
Undefined :: distinct rawptr
make_nil :: proc() -> Nil { return Nil{} }
make_undefined :: proc() -> Undefined { return Undefined{} }
make_rawptr :: proc() -> rawptr { return rawptr{} }
make_ptr :: proc() -> ^u8 { return {} }
`,
	)
	for name in ([?]string{"make_nil", "make_undefined", "make_rawptr", "make_ptr"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name)
		if ok { testing.expectf(t, procedure.body_state == .Complete, "%s", name) }
	}
}
