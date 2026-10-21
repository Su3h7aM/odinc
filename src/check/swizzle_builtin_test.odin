package check

import "core:testing"

@(test)
swizzle_builtin_preserves_unbounded_indices_and_shapes :: proc(t: ^testing.T) {
	source := `package sample
main :: proc "contextless" () {
 a: [300]int
 b: [6]int = swizzle(a, 299, 256, 0, 299, 1, 2)
 c: [5]int = swizzle(swizzle(a, 299, 256, 0, 1, 2, 3), 5, 4, 3, 2, 1)
 swizzle(a, 299, 256, 0, 299, 1, 2) = b
 _ = c
 v: #simd[4]i32
 w: #simd[8]i32 = swizzle(v, 3, 2, 1, 0, 3, 2, 1, 0)
 x: #simd[2]i32 = swizzle(swizzle(w, 7, 6, 5, 4), 3, 0)
 _ = x
}
`
	procedure, ok := check_procedure_source(t, transmute([]byte)source, diagnostic_count = 0)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
	for invalid in ([]string{`package sample
main :: proc "contextless" () { a: [4]int; _ = swizzle(a, 0) }`, `package sample
main :: proc "contextless" () { a: [4]int; _ = swizzle(a, -1, 0) }`, `package sample
main :: proc "contextless" () { a: [4]int; _ = swizzle(a, 4, 0) }`, `package sample
main :: proc "contextless" () { a: [4]int; i := 0; _ = swizzle(a, i, 0) }`, `package sample
main :: proc "contextless" () { a: #simd[4]i32; _ = swizzle(a, 0, 1, 2) }`}) {
		rejected, rejected_ok := check_procedure_source(t, transmute([]byte)invalid, .Invalid_Operand, diagnostic_count = 1)
		if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
	}
}
