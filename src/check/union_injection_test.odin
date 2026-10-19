package check

import "core:testing"

@(test)
union_assignment_injects_variants_only :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (number: u8, flag: bool) {
	value: union { u8, bool } = number
	value = flag
}
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid := transmute([]byte)string(`package sample
main :: proc "contextless" (number: u8) {
	value: union { bool } = number
}
`)
	rejected, rejected_ok := check_procedure_source(t, invalid)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}

@(test)
union_comparison_accepts_untyped_member_values :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" (id: union { int }) -> bool {
	return id == 1 && id != 2
}
`)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
