package check

import "core:testing"

@(test)
switch_fallthrough_accepts_non_type_switch_and_rejects_type_switch :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(`package sample
main :: proc "contextless" (value: int) {
	switch value {
	case 1:
		fallthrough
	case 2:
	}
}
`)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (value: union { u8, bool }) {
	switch v in value {
	case u8:
		fallthrough
	case bool:
	}
}
`,
	)
	rejected, rejected_ok := check_procedure_source(t, invalid)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}
