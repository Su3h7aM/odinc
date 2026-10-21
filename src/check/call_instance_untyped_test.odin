package check

import "core:testing"

@(test)
generic_untyped_argument_converts_to_typed_binding :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
bound :: proc "contextless" (x: $T, y: [2]T) -> T { return x + y[0] }
main :: proc "contextless" () {
	_ = bound(1, [2]u8{3, 4})
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
untyped_scalar_broadcasts_into_simd_vector :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	v: #simd[4]f64 = 2
	_ = v
}
`)
	procedure, ok := check_last_procedure_source(t, source)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}
