package check

import "core:testing"

@(test)
generic_call_expands_multi_result_argument :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
pair :: proc "contextless" () -> (u8, u8) { return 1, 2 }
must :: proc "contextless" (value: $T, err: u8) -> T { return value }
main :: proc "contextless" () {
	_ = must(pair())
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
generic_call_rejects_extra_expanded_argument :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
pair :: proc "contextless" () -> (u8, u8) { return 1, 2 }
add :: proc "contextless" (a: $T, b: T) -> T { return a }
main :: proc "contextless" () {
	_ = add(pair(), 3)
}
`,
	)
	rejected, ok := check_procedure_source(t, source, .Unsupported, "Call_Arguments")
	if ok { testing.expect(t, rejected.body_state == .Invalid) }
}
