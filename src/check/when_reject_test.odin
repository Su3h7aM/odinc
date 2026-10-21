package check

import "core:testing"

// A `when` over a runtime local is well-typed but not constant. It must be
// rejected with a diagnostic rather than crash the compiler.
@(test)
when_over_runtime_local_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	x := 3
	when x > 2 {
		_ = x
	}
}
`)
	_, ok := check_procedure_source(t, source, .Unsupported, "When_Condition")
	testing.expect(t, ok)
}
