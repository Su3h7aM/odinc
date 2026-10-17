package check

import "core:testing"

@(test)
named_results_publish_locals_and_reject_defer_assignment :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(`package sample
main :: proc "contextless" () -> (value: u8) {
	value = 7
	return
}
`)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	testing.expect_value(t, len(procedure.results), 1)

	invalid := transmute([]byte)string(`package sample
main :: proc "contextless" () -> (value: u8) {
	defer value = 7
}
`)
	rejected, rejected_ok := check_procedure_source(t, invalid)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}
