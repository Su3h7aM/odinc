package check

import "core:testing"

@(test)
or_branch_checks_scalar_status_expressions :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Error :: enum { None, Failure }
main :: proc "contextless" (ready: bool, pointer: ^int, error: Error) {
	outer: for {
		ready or_continue
		(ready == false) or_break
		pointer or_continue outer
		error or_break outer
		true or_continue
		false or_break
	}
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !testing.expect(t, ok) { return }
	testing.expect(t, procedure.body_state == .Complete)
	invalid := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	for { 1 or_break }
}
`)
	_, rejected := check_procedure_source(t, invalid, .Unsupported, "Or_Branch_Status", diagnostic_count = 1)
	testing.expect(t, rejected)
}

@(test)
or_else_converts_selected_payload_not_whole_call :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Value :: union { int, f64 }
number :: proc "contextless" () -> (int, bool) { return 7, true }
text :: proc "contextless" () -> (string, bool) { return "text", true }
variant :: proc "contextless" () -> (Value, bool) { value: Value = 9; return value, false }
fallback :: proc "contextless" () -> int { return 13 }
main :: proc "contextless" () {
	value: int
	value = number() or_else 1
	name: string
	name = text() or_else "fallback"
	selected: Value = number() or_else fallback()
	converted := variant() or_else fallback()
	_, _, _, _ = value, name, selected, converted
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !testing.expect(t, ok) { return }
	testing.expect(t, procedure.body_state == .Complete)
}
