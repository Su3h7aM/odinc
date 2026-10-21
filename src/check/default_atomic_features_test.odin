package check

import "core:testing"

@(test)
default_atomic_and_cpu_features_match_x86_64_v2 :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc() {
	#assert(atomic_type_is_lock_free(i128))
	#assert(has_target_feature("cx16"))
	#assert(has_target_feature("sse4.2"))
	#assert(!has_target_feature("avx"))
}
`,
	)
	procedure, ok := check_procedure_source(
		t,
		source,
		diagnostic_count = 0,
		type_diagnostic_count = 0,
		intrinsic_names = {"atomic_type_is_lock_free", "has_target_feature"},
		target_features = DEFAULT_BUILD_CONFIGURATION.target_features,
	)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}
