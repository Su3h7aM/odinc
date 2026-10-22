package check

import "core:testing"

@(test)
simd_shuffle_accepts_typed_integer_constant_indices :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc(v: #simd[4]i32) -> #simd[4]i32 {
	INDEX :: u32(3)
	return simd_shuffle(v, v, INDEX & 3, u32(2), 1, 0)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, intrinsic_names = {"simd_shuffle"})
	if testing.expect(t, ok) { testing.expect(t, procedure.body_state == .Complete) }
}
