package check

import "core:testing"

@(test)
simd_reductions_check_element_and_result_types :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
bits :: proc(v: #simd[4]u32) -> u32 { return simd_reduce_or(v) }
maximum :: proc(v: #simd[4]f32) -> f32 { return simd_reduce_max(v) }
bad :: proc(v: #simd[4]f32) -> f32 { return simd_reduce_or(v) }
`,
	)
	names := []string{"simd_reduce_or", "simd_reduce_max"}
	for name in ([?]string{"bits", "maximum"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name, intrinsic_names = names)
		if ok { testing.expect(t, procedure.body_state == .Complete) }
	}
	procedure, ok := check_procedure_source(t, source, procedure_name = "bad", intrinsic_names = names)
	if ok { testing.expect(t, procedure.body_state == .Invalid) }
}
