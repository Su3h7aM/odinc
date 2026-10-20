package check

import "core:testing"

@(test)
binary_bit_set_literal_rejects_unknown_member :: proc(t: ^testing.T) {
	// Official: Undeclared name 'Missing' for type 'enum int {A, B, C}'.
	source := transmute([]byte)string(
		`package sample
E :: enum { A, B, C }
S :: bit_set[E]
main :: proc "contextless" () {
	s := S{.A, .B}
	_ = s + {.Missing}
}
`,
	)
	_, ok := check_procedure_source(t, source, .Undeclared_Name)
	testing.expect(t, ok)
}

@(test)
membership_literal_cannot_infer_set_from_element :: proc(t: ^testing.T) {
	// Official: Missing type in compound literal; the element does not identify a bit_set type.
	source := transmute([]byte)string(`package sample
E :: enum { A, B, C }
main :: proc "contextless" () {
	_ = E.A in {.A, .B}
}
`)
	_, ok := check_procedure_source(t, source, .Unsupported, "Composite_Implicit_Type")
	testing.expect(t, ok)
}

@(test)
binary_rejects_mixed_integer_types :: proc(t: ^testing.T) {
	// Official: Mismatched types in binary expression 'a + b' : 'i32' vs 'i64'.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a: i32
	b: i64
	_ = a + b
}
`)
	_, ok := check_procedure_source(t, source, .Mismatched_Types, "")
	testing.expect(t, ok)
}

@(test)
binary_accepts_mixed_integer_cast :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a: i32
	b: i64
	_ = a + i32(b)
}
`)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

@(test)
binary_rejects_untyped_bitwise_not :: proc(t: ^testing.T) {
	// Official: Bitwise not cannot be applied to untyped constants '~0'.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () { x: u32 = ~0 }
`)
	_, ok := check_procedure_source(t, source, .Conversion, "")
	testing.expect(t, ok)
}

@(test)
binary_accepts_typed_bitwise_not :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () { x: u32 = ~u32(0) }
`)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

@(test)
binary_rejects_bool_arithmetic :: proc(t: ^testing.T) {
	// Official: Operator '+' is only allowed with numeric expressions.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () { _ = true + false }
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator, "")
	testing.expect(t, ok)
}

@(test)
binary_rejects_integer_string_comparison :: proc(t: ^testing.T) {
	// Official: Cannot convert untyped value '1' to 'untyped string' from 'untyped integer'.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () { _ = 1 < "a" }
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator, "")
	testing.expect(t, ok)
}

@(test)
unary_rejects_negative_unsigned_constant :: proc(t: ^testing.T) {
	// Official: Cannot convert numeric value '-1' from '-1' to 'u8' from 'untyped integer'. A negative value cannot be represented by the unsigned integer type 'u8'.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () { x: u8 = -1 }
`)
	_, ok := check_procedure_source(t, source, .Conversion, "")
	testing.expect(t, ok)
}

@(test)
binary_rejects_different_array_lengths_for_equality :: proc(t: ^testing.T) {
	// Official: Cannot compare expression. Mismatched types '[3]int' and '[4]int'.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a: [3]int
	b: [4]int
	_ = a == b
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator, "")
	testing.expect(t, ok)
}

@(test)
binary_rejects_float_shift :: proc(t: ^testing.T) {
	// Official: Shifted operand 'f' must be an integer.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () { f: f32; _ = f << 1 }
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator, "")
	testing.expect(t, ok)
}

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
