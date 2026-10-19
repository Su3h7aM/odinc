package check

import "core:testing"

@(test)
comparison_accepts_typed_operands_assignable_either_way :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" (value: ^u8, pointer: rawptr) -> bool {
	_ = type_parameter_kind("x")
	return pointer == value && value == pointer
}
type_parameter_kind :: proc "contextless" (value: $T) -> int {
	when T == bool { return 1 }
	return 0
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
