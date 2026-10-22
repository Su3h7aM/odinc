package driver

import "core:testing"

@(test)
half_precision_square_root_rounds_to_half :: proc(t: ^testing.T) {
	expect_exit(t, "half_sqrt", 0)
}

@(test)
string_pointer_range_decodes_runes_and_offsets :: proc(t: ^testing.T) {
	expect_exit(t, "string_pointer_range", 0)
}

@(test)
optional_assertion_address_preserves_payload_and_failure :: proc(t: ^testing.T) {
	expect_exit(t, "optional_assertion_address", 0)
}
