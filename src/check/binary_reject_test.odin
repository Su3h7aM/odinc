package check

import "core:testing"

@(test)
binary_rejects_array_ordering :: proc(t: ^testing.T) {
	// "Cannot compare expression. Operator '<' not defined between the types '[3]int' and '[3]int'." (official: ordering on [3]int arrays is REJECTED)
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a: [3]int = {1,2,3}
	b: [3]int = {1,2,3}
	x := a < b
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator)
	if !ok { return }
}

@(test)
binary_rejects_struct_ordering :: proc(t: ^testing.T) {
	// "Cannot compare expression. Operator '<' not defined between the types 'S' and 'S'."
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	S :: struct { a: int }
	x: S
	y: S
	z := x < y
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator)
	if !ok { return }
}

@(test)
binary_rejects_union_ordering :: proc(t: ^testing.T) {
	// "Cannot compare expression. Operator '<' not defined between the types 'U' and 'U'."
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	U :: union { int }
	x: U
	y: U
	z := x < y
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator)
	if !ok { return }
}

@(test)
binary_rejects_nonconst_string_add :: proc(t: ^testing.T) {
	// "String concatenation is only allowed with constant strings"
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a := "x"
	b := "y"
	c := a + b
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator)
	if !ok { return }
}

@(test)
binary_rejects_f32_mod :: proc(t: ^testing.T) {
	// "Operator '%' is only allowed with integers"
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a: f32 = 1
	b: f32 = 2
	c := a % b
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator)
	if !ok { return }
}

@(test)
binary_accepts_array_eq_and_bitset_lt :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	a: [3]int = {1,2,3}
	b: [3]int = {1,2,3}
	eq := a == b
	bs1: bit_set[0..3]
	bs2: bit_set[0..3]
	lt := bs1 < bs2
}
`,
	)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
	testing.expect(t, ok)
}
