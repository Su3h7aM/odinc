package check

import "core:testing"

@(test)
target_baseline_defaults_to_v1_with_explicit_v2 :: proc(t: ^testing.T) {
	baseline := transmute([]byte)string(
		`package sample
main :: proc() {
	#assert(!atomic_type_is_lock_free(i128))
	#assert(has_target_feature("sse2"))
	#assert(!has_target_feature("cx16"))
	#assert(!has_target_feature("sse4.2"))
	#assert(!has_target_feature("avx"))
}
`,
	)
	procedure, ok := check_procedure_source(
		t,
		baseline,
		diagnostic_count = 0,
		type_diagnostic_count = 0,
		intrinsic_names = {"atomic_type_is_lock_free", "has_target_feature"},
	)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
	raised := transmute([]byte)string(
		`package sample
main :: proc() {
	#assert(atomic_type_is_lock_free(i128))
	#assert(has_target_feature("cx16"))
	#assert(has_target_feature("sse4.2"))
	#assert(!has_target_feature("avx"))
}
`,
	)
	elevated, elevated_ok := check_procedure_source(
		t,
		raised,
		diagnostic_count = 0,
		type_diagnostic_count = 0,
		intrinsic_names = {"atomic_type_is_lock_free", "has_target_feature"},
		microarch = .V2,
	)
	if elevated_ok { testing.expect(t, elevated.body_state == .Complete) }
}
