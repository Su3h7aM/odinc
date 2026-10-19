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
