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
