package check

import "core:testing"

@(test)
expression_or_else_checks_bool_and_nil_pointer_status_pairs :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (ok: bool, ptr: ^u8) -> u8 {
	value := bool_status(ok) or_else 9
	_ = pointer_status(ok, ptr) or_else 8
	return value
}
bool_status :: proc "contextless" (ok: bool) -> (u8, bool) { return 7, ok }
pointer_status :: proc "contextless" (ok: bool, ptr: ^u8) -> (u8, ^u8) { return 7, ptr }
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid_sources := [?][]byte {
		transmute([]byte)string(`package sample
main :: proc "contextless" (ok: bool) -> u8 { return ok or_else 9 }
`),
		transmute([]byte)string(`package sample
main :: proc "contextless" (ptr: ^u8) -> ^u8 { return ptr or_else ptr }
`),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> u8 { return status(ok) or_else 9 }
status :: proc "contextless" (ok: bool) -> bool { return ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> u8 { return status(ok) or_else 9 }
status :: proc "contextless" (ok: bool) -> (u8, u8, bool) { return 7, 8, ok }
`,
		),
	}
	for source in invalid_sources {
		rejected, rejected_ok := check_procedure_source(t, source)
		if !rejected_ok { continue }
		testing.expect(t, rejected.body_state == .Invalid)
	}
}
