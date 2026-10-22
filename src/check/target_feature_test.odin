package check

import "core:testing"

@(test)
target_feature_attributes_conflict :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
@(require_target_feature="sse4.2")
@(enable_target_feature="avx2")
both :: proc() {
}
main :: proc() {
}
`,
	)
	_, ok := check_procedure_source(
		t,
		source,
		.Target_Feature,
		`A procedure cannot have both @(require_target_feature="...") and @(enable_target_feature="...")`,
		diagnostic_count = 1,
	)
	testing.expect(t, ok)
}

@(test)
target_feature_attributes_invalid_name :: proc(t: ^testing.T) {
	declared := transmute([]byte)string(`package sample
@(require_target_feature="fma7")
bad_attr :: proc() {
}
main :: proc() {
}
`)
	_, declared_ok := check_procedure_source(
		t,
		declared,
		.Target_Feature,
		"Required target feature 'fma7' is not a valid target feature",
		diagnostic_count = 1,
	)
	testing.expect(t, declared_ok)
	called := transmute([]byte)string(`package sample
@(require_target_feature="fma7")
bad_attr :: proc() {
}
main :: proc() {
	bad_attr()
}
`)
	_, called_ok := check_procedure_source(
		t,
		called,
		.Target_Feature,
		"Called procedure requires target feature 'fma7' which is invalid for the build target",
		diagnostic_count = 2,
	)
	testing.expect(t, called_ok)
	enabled := transmute([]byte)string(`package sample
@(enable_target_feature="fma7")
bad_enable :: proc() {
}
main :: proc() {
}
`)
	_, enabled_ok := check_procedure_source(
		t,
		enabled,
		.Target_Feature,
		"Procedure enabled target feature 'fma7' is not a valid target feature",
		diagnostic_count = 1,
	)
	testing.expect(t, enabled_ok)
}

@(test)
target_feature_require_disabled_call :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
@(require_target_feature="sse4.2")
needs_sse42 :: proc() {
}
main :: proc() {
	needs_sse42()
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Target_Feature,
		"Calling this procedure requires target feature 'sse4.2' to be enabled",
		diagnostic_count = 1,
		intrinsic_names = {"has_target_feature"},
	)
	testing.expect(t, ok)
	elevated, elevated_ok := check_procedure_source(
		t,
		source,
		diagnostic_count = 0,
		type_diagnostic_count = 0,
		intrinsic_names = {"has_target_feature"},
		microarch = .V2,
	)
	if elevated_ok { testing.expect(t, elevated.body_state == .Complete) }
}

@(test)
target_feature_caller_enable_rescues_nothing :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
@(require_target_feature="sse4.2")
needs_sse42 :: proc() {
}
@(enable_target_feature="sse4.2")
caller :: proc() {
	needs_sse42()
}
main :: proc() {
	caller()
}
`,
	)
	_, ok := check_procedure_source(t, source, .Target_Feature, "Calling this procedure requires target feature 'sse4.2' to be enabled", diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
target_feature_query_is_global_in_enabled_procedure :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
@(enable_target_feature="avx2")
prober :: proc() {
	#assert(!has_target_feature("avx2"))
	#assert(has_target_feature("sse2"))
}
main :: proc() {
	prober()
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0, intrinsic_names = {"has_target_feature"})
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
target_feature_query_through_procedure_value :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
@(require_target_feature="sse4.2")
needs_sse42 :: proc() {
}
main :: proc() {
	#assert(!has_target_feature(needs_sse42))
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0, intrinsic_names = {"has_target_feature"})
	if ok { testing.expect(t, procedure.body_state == .Complete) }
	elevated_source := transmute([]byte)string(
		`package sample
@(require_target_feature="sse4.2")
needs_sse42 :: proc() {
}
main :: proc() {
	#assert(has_target_feature(needs_sse42))
}
`,
	)
	elevated, elevated_ok := check_procedure_source(
		t,
		elevated_source,
		diagnostic_count = 0,
		type_diagnostic_count = 0,
		intrinsic_names = {"has_target_feature"},
		microarch = .V2,
	)
	if elevated_ok { testing.expect(t, elevated.body_state == .Complete) }
	plain := transmute([]byte)string(`package sample
plain :: proc() {
}
main :: proc() {
	_ = has_target_feature(plain)
}
`)
	_, plain_ok := check_procedure_source(
		t,
		plain,
		.Invalid_Operand,
		"Expected the procedure type given to 'has_target_feature' to have @(require_target_feature=\"...\") or @(enable_target_feature=\"...\")",
		diagnostic_count = 1,
		intrinsic_names = {"has_target_feature"},
	)
	testing.expect(t, plain_ok)
	bogus := transmute([]byte)string(`package sample
main :: proc() {
	#assert(!has_target_feature("fma7"))
	#assert(!has_target_feature("neon"))
}
`)
	bogus_procedure, bogus_ok := check_procedure_source(t, bogus, diagnostic_count = 0, type_diagnostic_count = 0, intrinsic_names = {"has_target_feature"})
	if bogus_ok { testing.expect(t, bogus_procedure.body_state == .Complete) }
}

@(test)
target_feature_force_inline_call_rules :: proc(t: ^testing.T) {
	scoped := transmute([]byte)string(
		`package sample
@(enable_target_feature="avx2")
inline_enabled :: #force_inline proc "contextless" () -> int {
	return 1
}
result := inline_enabled()
main :: proc() {
	_ = result
}
`,
	)
	_, scoped_ok := check_procedure_source(
		t,
		scoped,
		.Target_Feature,
		"Calling a '#force_inline' procedure that enables target features is not allowed at file scope",
		diagnostic_count = 1,
	)
	testing.expect(t, scoped_ok)
	unrescued := transmute([]byte)string(
		`package sample
@(enable_target_feature="avx2")
inline_enabled :: #force_inline proc "contextless" () -> int {
	return 1
}
main :: proc() {
	_ = inline_enabled()
}
`,
	)
	_, unrescued_ok := check_procedure_source(
		t,
		unrescued,
		.Target_Feature,
		"Inlined procedure enables target feature 'avx2', this requires the calling procedure to at least enable the same feature\nSuggested Example: @(enable_target_feature=\"avx2\")",
		diagnostic_count = 1,
	)
	testing.expect(t, unrescued_ok)
	rescued := transmute([]byte)string(
		`package sample
@(enable_target_feature="avx2")
inline_enabled :: #force_inline proc "contextless" () -> int {
	return 1
}
@(enable_target_feature="avx2")
caller :: proc() {
	_ = inline_enabled()
}
main :: proc() {
	caller()
}
`,
	)
	procedure, rescued_ok := check_procedure_source(t, rescued, diagnostic_count = 0, type_diagnostic_count = 0)
	if rescued_ok { testing.expect(t, procedure.body_state == .Complete) }
}
