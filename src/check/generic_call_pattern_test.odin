package check

import "core:testing"

@(test)
generic_array_dimension_infers_enum_index :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Kind :: enum { A, B }
first :: proc(names: [$E]string) -> E { return {} }
main :: proc() { names: [Kind]string; _ = first(names) }
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0)
	testing.expect(t, ok)
}

@(test)
generic_callback_result_infers_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
apply :: proc(value: $E, key: proc(E) -> $K) -> K { return key(value) }
main :: proc() { _ = apply(1, proc(x: int) -> string { return "ok" }) }
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0)
	testing.expect(t, ok)
}
