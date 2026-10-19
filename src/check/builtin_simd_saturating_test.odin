package check

import "core:testing"

@(test)
simd_saturating_arithmetic_requires_matching_integer_vectors :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
add :: proc(a, b: #simd[4]i32) -> #simd[4]i32 { return simd_saturating_add(a, b) }
subtract :: proc(a, b: #simd[4]u32) -> #simd[4]u32 { return simd_saturating_sub(a, b) }
bad :: proc(a, b: #simd[4]f32) -> #simd[4]f32 { return simd_saturating_add(a, b) }
`,
	)
	for name in ([?]string{"add", "subtract", "bad"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name, intrinsic_names = []string{"simd_saturating_add", "simd_saturating_sub"})
		if ok { testing.expect(t, (procedure.body_state == .Complete) == (name != "bad")) }
	}
}
