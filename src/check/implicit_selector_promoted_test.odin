package check

import "core:testing"

@(test)
implicit_selectors_in_promoted_literal_fields :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
E :: enum uint { Zero, Last = ~uint(0) }
U :: struct #raw_union { special: E, handler: rawptr }
S :: struct { using u: U, count: int }
Inner :: struct { special: E, count: int }
Outer :: struct { padding: int, using inner: Inner }
constant :: Outer{special = .Last, count = 7}
main :: proc "contextless" () {
	a := S{special = .Zero, count = 3}
	b := S{u = {}, special = .Last}
	c := S{special = .Zero, u = {special = .Last}}
	d := Outer{inner = {.Last, 7}, special = .Zero}
	e := Outer{special = .Zero, inner = {.Last, 7}}
	#assert(constant.special == .Last)
	#assert(constant.count == 7)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
promoted_literal_fields_reject_duplicate_and_overlapping_leaves :: proc(t: ^testing.T) {
	for source in ([]string{`package sample
E :: enum { Zero }
U :: struct { special: E }
S :: struct { using u: U }
main :: proc() { a := S{special = .Zero, special = .Zero} }
`, `package sample
E :: enum { Zero }
U :: struct #raw_union { special: E, handler: rawptr }
S :: struct { using u: U }
main :: proc() { a := S{special = .Zero, handler = nil} }
`}) {
		_, ok := check_procedure_source(t, transmute([]byte)source, .Invalid_Operand, "", 1)
		testing.expect(t, ok)
	}
}
