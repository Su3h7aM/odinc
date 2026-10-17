package check

import "core:testing"

@(test)
unreachable_is_a_zero_argument_diverging_builtin :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	unreachable()
}
`)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	with_argument := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	unreachable(1)
}
`)
	rejected, rejected_ok := check_procedure_source(t, with_argument, true)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}

@(test)
user_unreachable_procedure_is_not_the_builtin :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	return unreachable()
}
unreachable :: proc "contextless" () -> u8 {
	return 7
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
unreachable_branch_keeps_nonvoid_continuation_valid :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	guard: bool = guard_value()
	if guard {
		unreachable()
	}
	return 0
}
guard_value :: proc "contextless" () -> bool {
	return 0 == 1
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
