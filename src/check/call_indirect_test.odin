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

@(test)
call_passes_type_to_typeid_parameter :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
is_pointer :: proc "contextless" (id: typeid) -> bool { return id == rawptr }
main :: proc "contextless" () -> bool { return is_pointer(int) }
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
indirect_call_accepts_c_convention_and_proc_type_casts :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" (value: proc "c" (u8, u8) -> u8) -> u8 {
	operation := (proc "c" (u8, u8) -> u8)(value)
	return operation(1, 2)
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
