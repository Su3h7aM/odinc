package check

import "core:testing"

@(test)
simd_extract_msbs_checks_integer_boolean_lanes_and_bit_set_result :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
entry :: proc(v: #simd[16]u8) -> bit_set[0..<16] { return simd_extract_msbs(v) }
signed :: proc(v: #simd[4]i128) -> bit_set[0..<4] { return simd_extract_msbs(v) }
booleans :: proc(v: #simd[4]bool) -> bit_set[0..<4] { return simd_extract_msbs(v) }
boundary :: proc(v: #simd[64]u8) -> bit_set[0..<64] { return simd_extract_msbs(v) }
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, intrinsic_names = {"simd_extract_msbs"}, procedure_name = "entry")
	if !testing.expect(t, ok) { return }
	testing.expect(t, procedure.body_state == .Complete)
	floating := transmute([]byte)string(`package sample
entry :: proc(v: #simd[4]f32) { _ = simd_extract_msbs(v) }
`)
	_, rejected := check_procedure_source(
		t,
		floating,
		.Invalid_Operand,
		diagnostic_count = 1,
		procedure_name = "entry",
		intrinsic_names = {"simd_extract_msbs"},
	)
	testing.expect(t, rejected)
	too_many := transmute([]byte)string(`package sample
entry :: proc(v: #simd[128]u8) { _ = simd_extract_msbs(v) }
`)
	_, bounded := check_procedure_source(t, too_many, type_diagnostic_count = 1, procedure_name = "entry", intrinsic_names = {"simd_extract_msbs"})
	testing.expect(t, bounded)
}
