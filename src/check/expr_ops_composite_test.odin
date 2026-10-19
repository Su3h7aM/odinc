package check

import "core:testing"

@(test)
equality_hints_implicit_composite_literal_with_left_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
is_origin :: proc(p: [2]int) -> bool {
	return p == {0, 0}
}
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "is_origin")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
equality_accepts_comparable_struct_operands :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
Point :: struct { x, y: int }
same :: proc(p, q: Point) -> bool {
	return p == q
}
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "same")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}
