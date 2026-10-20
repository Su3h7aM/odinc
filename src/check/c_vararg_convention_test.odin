package check

import "core:testing"

@(test)
c_vararg_requires_a_compatible_calling_convention :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
odin :: proc(first: int, #c_vararg values: ..int) -> int { return first }
contextless :: proc "contextless" (first: int, #c_vararg values: ..int) -> int { return first }
main :: proc() {}
`,
	)
	_, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 2)
	testing.expect(t, ok)
}
