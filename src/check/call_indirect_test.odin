package check

import "core:testing"

@(test)
indirect_call_checks_procedure_value_arity :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	operation: proc "contextless" (u8, u8) -> u8
	return operation(1, 2)
}
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	short := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	operation: proc "contextless" (u8, u8) -> u8
	return operation(1)
}
`,
	)
	rejected, rejected_ok := check_procedure_source(t, short)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}
