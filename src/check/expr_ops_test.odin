package check

import "core:testing"

@(test)
modulo_accepts_untyped_float_constant_as_integer_operand :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
nanos :: proc "contextless" (value: int) -> int { return value % 1e9 }
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "nanos")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
equality_compares_typeid_value_with_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
is_pointer_type :: proc "contextless" (id: typeid) -> bool { return id == rawptr }
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "is_pointer_type")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}
