package check

import "core:testing"

@(test)
abs_accepts_complex_and_quaternion_operands :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	q := 1 + 2i + 3j + 4k
	magnitude: f64 = abs(q)
	c := 3 + 4i
	length: f64 = abs(c)
	narrow: complex32 = 3 + 4i
	pair16: f16 = abs(narrow)
	wide: complex64 = 3 + 4i
	pair32: f32 = abs(wide)
	full: complex128 = 3 + 4i
	pair64: f64 = abs(full)
	small: quaternion64 = 1 + 2i + 3j + 4k
	quad16: f16 = abs(small)
	medium: quaternion128 = 1 + 2i + 3j + 4k
	quad32: f32 = abs(medium)
	large: quaternion256 = 1 + 2i + 3j + 4k
	quad64: f64 = abs(large)
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
abs_folds_complex_and_quaternion_constants :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	five: f64 = abs(3 + 4i + 0j + 0k)
	also_five: f64 = abs(3 + 4i)
	constructed: f32 = abs(quaternion(w = 3, x = 4, y = 0, z = 0))
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
