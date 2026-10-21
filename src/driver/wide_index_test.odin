package driver

import "core:testing"
import "oc:ir"

// A 128-bit index addresses its low word; lowering must narrow it instead of
// feeding the value's slot address to the address arithmetic.
@(test)
wide_index_reads_low_word :: proc(t: ^testing.T) {
	expect_exit(t, "wide_index_u128", 42)
}

// A set high word is out of bounds and traps with bounds checks on.
@(test)
wide_index_high_word_traps :: proc(t: ^testing.T) {
	result, ok := run_section(t, "wide_index_u128_oob")
	defer delete(result.output, context.allocator)
	if !ok { return }
	testing.expect_value(t, result.outcome, ir.Interp_Outcome.Trap)
}
