package check

import "core:testing"

// Official odin accepts these forms (checked with the official compiler: `3 + 4i` and `a == 1` are accepted, as are the operators below).
@(test)
complex_operators_and_untyped_constants_check :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	a: complex128 = complex(1.0, 2.0)
	b: complex128 = 3 + 4i
	d: complex128 = 4i
	_ = a + b
	_ = a - b
	_ = a * b
	_ = a / b
	_ = -a
	_ = +a
	_ = a == b
	_ = a != b
	_ = a + 2
	_ = 2 * a
	_ = a == 1
	_ = a / 2.5
	_ = d
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

// Official odin rejects `%` on complex operands: "Operator '%%' is only allowed with integers".
@(test)
complex_modulo_is_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a, b: complex128
	_ = a % b
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator, "")
	testing.expect(t, ok)
}

// Official odin rejects mixing complex widths: "Mismatched types in binary expression 'a + b' : 'complex64' vs 'complex128'".
@(test)
complex_mixed_widths_are_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	a: complex64
	b: complex128
	_ = a + b
}
`)
	_, ok := check_procedure_source(t, source, .Mismatched_Types, "")
	testing.expect(t, ok)
}
