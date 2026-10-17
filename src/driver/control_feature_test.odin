package driver

import "core:testing"

@(test)
section_33_defer_runs_at_scope_break_and_return_exits_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_33", 93)
}

@(test)
section_34_named_results_capture_values_before_defers :: proc(t: ^testing.T) {
	expect_exit(t, "section_34", 21)
}

@(test)
section_35_indirect_calls_through_procedure_values :: proc(t: ^testing.T) {
	expect_exit(t, "section_35", 24)
}

@(test)
probe_1_plain_block_assignment :: proc(t: ^testing.T) {
	expect_exit(t, "probe_1", 3)
}

@(test)
probe_2_defer_after_return_value :: proc(t: ^testing.T) {
	expect_exit(t, "probe_2", 1)
}

@(test)
probe_3_block_defer :: proc(t: ^testing.T) {
	expect_exit(t, "probe_3", 9)
}

@(test)
probe_4_return_in_if :: proc(t: ^testing.T) {
	expect_exit(t, "probe_4", 5)
}
