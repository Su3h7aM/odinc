package driver

import "core:testing"

@(test)
bool_to_byte_conversion_uses_one_extension :: proc(t: ^testing.T) {
	expect_exit(t, "bool_to_byte", 0)
}

@(test)
parenthesized_constants_keep_contextual_types :: proc(t: ^testing.T) {
	expect_exit(t, "parenthesized_constants", 0)
}

@(test)
ternary_arms_inject_union_variants :: proc(t: ^testing.T) {
	expect_exit(t, "ternary_union_arms", 0)
}
