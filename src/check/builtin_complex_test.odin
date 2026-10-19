package check

import "core:testing"

@(test)
complex_and_quaternion_builtins_check_constants :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	complex_value :: complex(1, 2.0)
	quaternion_value :: quaternion(imag = 1, jmag = 2, kmag = 3, real = 4)
	real(complex_value)
	imag(complex_value)
	real(quaternion_value)
	jmag(quaternion_value)
	kmag(quaternion_value)
	conj(quaternion_value)
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
complex_builtin_takes_distinct_complex_hint :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
complex_double :: distinct complex128
main :: proc "contextless" (x, y: f64) -> complex_double {
	return complex(x, y)
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
