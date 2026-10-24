package lower

import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:types"

@(test)
extract_msbs_internal_128_lanes_preserves_word_boundaries :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	byte := types.sized_integer(&store, 1, false)
	integer := types.sized_integer(&store, 8, true)
	vector_type := types.intern(&store, types.Type{kind = .Simd_Vector, elem = byte, count = 128})
	result_type := types.intern(
		&store,
		types.Type{kind = .Bit_Set, elem = integer, lower_bound = 0, upper_bound = 127, enum_lower_bound = 0, enum_upper_bound = 127},
	)
	layouts, layout_error := prepare_layouts(&store, context.allocator)
	if !testing.expect_value(t, layout_error, nil) { return }
	defer delete(layouts)
	function, function_error := ir.function_make(context.allocator, 0, "extract_msbs_128", 0)
	if !testing.expect_value(t, function_error, nil) { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{results = {{type = .I64}}})
	entry := ir.start(function)
	builder, builder_error := ir.builder_make(context.allocator, function, entry)
	if !testing.expect_value(t, builder_error, nil) { return }
	defer ir.builder_destroy(builder)
	program := check.Checked_Program {
		type_data = &store,
	}
	job := Procedure_Job {
		program  = &program,
		function = function,
		layouts  = layouts,
	}
	state := Procedure_State {
		job           = &job,
		builder       = builder,
		entry_control = entry.control,
	}
	address := ir.stack_slot(function, entry.control, 128, 16)
	lower_zero_memory(&state, address, 128)
	for lane in ([4]i64{0, 63, 64, 127}) {
		lower_store_word(&state, ir.ptr_offset(function, address, lane), ir.const_int(function, .I8, 0x80))
	}
	mask := lower_simd_extract_bits(&state, 0, result_type, vector_type, address, true)
	if !testing.expect(t, !state.failed && function.error == nil) { return }
	words := wide_load(&state, mask)
	expected := ir.const_int(function, .I64, transmute(i64)u64(0x8000_0000_0000_0001))
	difference := ir.binary(function, .Or, ir.binary(function, .Xor, words.low, expected), ir.binary(function, .Xor, words.high, expected))
	ir.emit_return(builder, difference)
	if !testing.expect_value(t, ir.function_finish(function), nil) { return }
	module: ir.Module
	module.functions.allocator = context.allocator
	if _, append_error := append(&module.functions, function); !testing.expect_value(t, append_error, nil) { return }
	defer delete(module.functions)
	actual, run_error := ir.interp_run(&module, function, nil, 10000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(0))
}
