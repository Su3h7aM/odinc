package check

import "core:testing"

@(test)
defined_directive_is_false_for_undeclared_names_without_diagnostic :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	when #defined(_missing_native) {
		_ = undeclared_in_dead_branch
	} else {
		_ = 2
	}
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
