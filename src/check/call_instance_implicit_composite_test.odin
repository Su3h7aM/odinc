package check

import "core:testing"

@(test)
generic_calls_hint_implicit_composite_arguments :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Kind :: enum { A, B }
consume :: proc(first: $T, value: bit_set[Kind]) {}
main :: proc() {
	consume(1, {.A, .B})
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}
