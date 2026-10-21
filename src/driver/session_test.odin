package driver

import "core:path/filepath"
import "core:testing"
import "oc:ir"
import "oc:lower"

// Runs testdata/<section>/main.odin through the driver, lowering and the interpreter, and returns the interpreter result.
run_section :: proc(t: ^testing.T, section: string) -> (result: ir.Interp_Result, ok: bool) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", section, "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	if !testing.expectf(t, err == .None, "%v", err) { return }

	module: ir.Module
	lower_errors, lower_error := lower.lower_program(&session.program, &module, context.allocator)
	defer delete(lower_errors, context.allocator)
	defer ir.module_destroy(&module)
	if !testing.expectf(t, lower_error == nil && len(lower_errors) == 0, "%v %v", lower_error, lower_errors) { return }

	main_name := main_symbol_name(session)
	main_function: ^ir.Function
	for function in module.functions {
		if function.name == main_name { main_function = function }
	}
	if !testing.expect(t, main_function != nil) { return }
	// Zeroed arguments include the implicit context pointer, which the fixtures never read.
	arguments := make([]u64, len(main_function.signatures[main_function.signature].params), context.temp_allocator)
	run_result, run_error := ir.interp_run(&module, main_function, arguments, 100_000, context.allocator)
	testing.expect(t, run_error == nil)
	return run_result, run_error == nil
}

expect_exit :: proc(t: ^testing.T, section: string, code: u64) {
	result, ok := run_section(t, section)
	defer delete(result.output, context.allocator)
	if !ok { return }
	testing.expect_value(t, result.outcome, ir.Interp_Outcome.Exit)
	testing.expect_value(t, result.value, code)
}

@(test)
section_19_program_from_driver_exits :: proc(t: ^testing.T) {
	result, ok := run_section(t, "section_19")
	defer delete(result.output, context.allocator)
	if !ok { return }
	testing.expect_value(t, result.outcome, ir.Interp_Outcome.Exit)
	testing.expect_value(t, result.value, u64(0))
	testing.expect(t, string(result.output) == "abcde\n")
}

@(test)
section_20_procedure_call_exits_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_20", 5)
}

@(test)
section_21_loops_and_control_flow_exit_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_21", 127)
}

@(test)
section_22_pointers_compound_and_short_circuit_exit_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_22", 71)
}

@(test)
section_23_universe_and_argument_conversion_exit_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_23", 200)
}

@(test)
section_24_switch_exits_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_24", 122)
}

@(test)
section_25_structs_exit_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_25", 37)
}

// Passing f64 to a union parameter injects it, so lowering must read the source type f64, not the union.
@(test)
union_argument_injection_lowers_from_the_source_type :: proc(t: ^testing.T) {
	expect_exit(t, "demo_section_union_type", 12)
}

@(test)
section_26_arrays_slices_and_len_exit_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_26", 47)
}

@(test)
section_27_out_of_range_slice_index_traps :: proc(t: ^testing.T) {
	result, ok := run_section(t, "section_27")
	defer delete(result.output, context.allocator)
	if !ok { return }
	testing.expect_value(t, result.outcome, ir.Interp_Outcome.Trap)
}

@(test)
section_28_strings_len_and_index_exit_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "section_28", 128)
}

@(test)
declared_variable_assignment_exits_with_value :: proc(t: ^testing.T) {
	expect_exit(t, "declared_assignment", 1)
}

@(test)
string_comparison_exits_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "string_compare", 63)
}

@(test)
string_switch_exits_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "string_switch", 3)
}

@(test)
cstring_literals_compare_with_terminators :: proc(t: ^testing.T) {
	expect_exit(t, "cstring_literals", 3)
}

@(test)
utf16_literals_keep_code_unit_lengths_and_terminators :: proc(t: ^testing.T) {
	expect_exit(t, "utf16_literals", 31)
}

@(test)
complex_abs_and_conj_exit_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "complex_abs_conj", 4095)
}
