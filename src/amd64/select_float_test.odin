package amd64

import "core:testing"
import "oc:ir"
import "oc:types"

@(test)
selected_float_arithmetic_compare_convert_and_call :: proc(t: ^testing.T) {
	selected_float_loop_exits_with_fifty_five(t)
	selected_float_program(t)
}

@(private)
float64 :: proc(function: ^ir.Function, value: f64) -> ir.Node_Id {
	return ir.const_float(function, .F64, transmute(u64)value)
}

@(private)
float32 :: proc(function: ^ir.Function, value: f32) -> ir.Node_Id {
	return ir.const_float(function, .F32, u64(transmute(u32)value))
}

@(private)
bool_not :: proc(function: ^ir.Function, value: ir.Node_Id) -> ir.Node_Id {
	return ir.binary(function, .Xor, value, ir.const_int(function, .Bool, 1))
}

@(private)
bool_and :: proc(function: ^ir.Function, left, right: ir.Node_Id) -> ir.Node_Id {
	return ir.binary(function, .And, left, right)
}

@(private)
score_bit :: proc(function: ^ir.Function, score, condition: ir.Node_Id, weight: i64) -> ir.Node_Id {
	added := ir.binary(function, .Add, score, ir.const_int(function, .I64, weight))
	return ir.select(function, condition, added, score)
}

@(private)
selected_float_loop_exits_with_fifty_five :: proc(t: ^testing.T) {
	function, make_err := ir.function_make(context.allocator, 0, "_start", 0)
	testing.expect_value(t, make_err, nil)
	if make_err != nil { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	entry := ir.start(function)
	builder, builder_err := ir.builder_make(context.allocator, function, entry)
	testing.expect_value(t, builder_err, nil)
	if builder_err != nil { return }
	defer ir.builder_destroy(builder)
	one := ir.const_int(function, .I64, 1)
	ten := ir.const_int(function, .I64, 10)
	index := ir.variable_declare(builder, one)
	sum := ir.variable_declare(builder, float64(function, 0))
	exit_target := ir.jump_target_make(builder)
	loop := ir.loop_begin(builder, {index, sum})
	branch := ir.branch_if(builder, ir.compare(function, .SLe, ir.variable_get(builder, index), ten))
	ir.enter_arm(builder, branch, 1)
	ir.jump_to(builder, exit_target)
	ir.enter_arm(builder, branch, 0)
	step := ir.convert(function, .Sint_To_Float, ir.variable_get(builder, index), .F64)
	ir.variable_set(builder, sum, ir.binary(function, .FAdd, ir.variable_get(builder, sum), step))
	ir.variable_set(builder, index, ir.binary(function, .Add, ir.variable_get(builder, index), one))
	ir.loop_end(builder, loop)
	testing.expect(t, ir.seal_target(builder, exit_target))
	total := ir.convert(function, .Float_To_Sint, ir.variable_get(builder, sum), .I64)
	exit_call := ir.add_node(
		function,
		.Syscall,
		.Tuple,
		{builder.control, ir.variable_get(builder, ir.MEMORY_VARIABLE), ir.const_int(function, .I64, 231), total},
	)
	memory := ir.add_node(function, .Proj, .Memory, {exit_call}, {index = 0})
	ir.unreachable(function, builder.control, memory)
	testing.expect_value(t, ir.builder_finish(builder), nil)
	selected_test_run(t, function, 55)
}

@(private)
selected_float_program :: proc(t: ^testing.T) {
	callee_parameters := []ir.Param {
		{type = .I64},
		{type = .F64},
		{type = .F64},
		{type = .F64},
		{type = .F64},
		{type = .F64},
		{type = .F64},
		{type = .F64},
		{type = .F64},
		{type = .F64},
		{type = .I64},
	}
	callee_results := []ir.Result{{type = .F64}}
	callee_signature := ir.Signature {
		cc      = .C,
		params  = callee_parameters,
		results = callee_results,
	}
	callee, callee_err := ir.function_make(context.allocator, 1, "mix", 0)
	testing.expect_value(t, callee_err, nil)
	if callee_err != nil { return }
	defer ir.function_destroy(callee)
	ir.add_signature(callee, callee_signature)
	callee_entry := ir.start(callee)
	integer_sum := ir.binary(callee, .Add, callee_entry.params[0], callee_entry.params[10])
	float_sum := ir.convert(callee, .Sint_To_Float, integer_sum, .F64)
	for index in 1 ..= 9 {
		float_sum = ir.binary(callee, .FAdd, float_sum, callee_entry.params[index])
	}
	ir.ret(callee, callee_entry.control, callee_entry.memory, float_sum)
	testing.expect_value(t, ir.function_finish(callee), nil)

	function, make_err := ir.function_make(context.allocator, 0, "_start", 0)
	testing.expect_value(t, make_err, nil)
	if make_err != nil { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	callee_index := ir.add_signature(function, callee_signature)
	entry := ir.start(function)
	memory := entry.memory

	quotient := ir.binary(
		function,
		.FDiv,
		ir.binary(
			function,
			.FSub,
			ir.binary(function, .FMul, ir.binary(function, .FAdd, float64(function, 1.5), float64(function, 2.5)), float64(function, 4)),
			float64(function, 2),
		),
		float64(function, 2),
	)
	narrow_quotient := ir.binary(
		function,
		.FDiv,
		ir.binary(
			function,
			.FSub,
			ir.binary(function, .FMul, ir.binary(function, .FAdd, float32(function, 1.5), float32(function, 2.5)), float32(function, 4)),
			float32(function, 2),
		),
		float32(function, 2),
	)
	negated := ir.unary(function, .FNeg, ir.unary(function, .FNeg, float64(function, 3)))
	root := ir.unary(function, .FSqrt, float64(function, 9))
	arithmetic := bool_and(
		function,
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Sint, quotient, .I64), ir.const_int(function, .I64, 7)),
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Sint, narrow_quotient, .I64), ir.const_int(function, .I64, 7)),
	)
	arithmetic = bool_and(function, arithmetic, ir.compare(function, .FEq, negated, float64(function, 3)))
	arithmetic = bool_and(function, arithmetic, ir.compare(function, .FEq, root, float64(function, 3)))

	one := float64(function, 1)
	two := float64(function, 2)
	nan := ir.const_float(function, .F64, 0x7ff8_0000_0000_0000)
	nan32 := ir.const_float(function, .F32, 0x7fc0_0000)
	compared := ir.compare(function, .FEq, one, one)
	compared = bool_and(function, compared, bool_not(function, ir.compare(function, .FEq, nan, nan)))
	compared = bool_and(function, compared, ir.compare(function, .FNe, nan, one))
	compared = bool_and(function, compared, bool_not(function, ir.compare(function, .FLt, nan, one)))
	compared = bool_and(function, compared, bool_not(function, ir.compare(function, .FLe, one, nan)))
	compared = bool_and(function, compared, bool_not(function, ir.compare(function, .FNe, one, one)))
	compared = bool_and(function, compared, ir.compare(function, .FLt, one, two))
	compared = bool_and(function, compared, ir.compare(function, .FLe, two, two))
	compared = bool_and(function, compared, bool_not(function, ir.compare(function, .FLt, two, one)))
	compared = bool_and(function, compared, bool_not(function, ir.compare(function, .FLe, two, one)))
	compared = bool_and(function, compared, ir.compare(function, .FNe, nan32, float32(function, 1)))
	compared = bool_and(function, compared, bool_not(function, ir.compare(function, .FEq, nan32, nan32)))

	chosen := ir.select(function, ir.compare(function, .FEq, one, one), float64(function, 5), float64(function, 9))
	rejected := ir.select(function, ir.compare(function, .FLt, two, one), float64(function, 5), float64(function, 9))
	selected := bool_and(function, ir.compare(function, .FEq, chosen, float64(function, 5)), ir.compare(function, .FEq, rejected, float64(function, 9)))

	signed_value := ir.convert(function, .Sint_To_Float, ir.const_int(function, .I8, -5), .F64)
	unsigned_value := ir.convert(function, .Uint_To_Float, ir.const_int(function, .I32, -1_294_967_296), .F64)
	high_bits := transmute(i64)(u64(1) << 63)
	high := ir.const_int(function, .I64, high_bits)
	high_float := ir.convert(function, .Uint_To_Float, high, .F64)
	odd_raw := (u64(1) << 63) + 1025
	odd_float := ir.convert(function, .Uint_To_Float, ir.const_int(function, .I64, cast(i64)odd_raw), .F64)
	rounded := f64(odd_raw)
	high_float32 := ir.convert(function, .Uint_To_Float, high, .F32)
	widened := ir.convert(function, .Float_Ext, float32(function, 1.5), .F64)
	converted := ir.compare(function, .Eq, ir.convert(function, .Float_To_Sint, signed_value, .I32), ir.const_int(function, .I32, -5))
	converted = bool_and(
		function,
		converted,
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Uint, unsigned_value, .I64), ir.const_int(function, .I64, 3_000_000_000)),
	)
	converted = bool_and(function, converted, ir.compare(function, .FEq, high_float, float64(function, f64(u64(1) << 63))))
	converted = bool_and(function, converted, ir.compare(function, .FEq, odd_float, float64(function, rounded)))
	converted = bool_and(
		function,
		converted,
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Uint, float64(function, f64(u64(1) << 63)), .I64), high),
	)
	converted = bool_and(
		function,
		converted,
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Uint, float64(function, rounded), .I64), ir.const_int(function, .I64, i64(u64(rounded)))),
	)
	converted = bool_and(
		function,
		converted,
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Uint, float64(function, 3), .I64), ir.const_int(function, .I64, 3)),
	)
	converted = bool_and(
		function,
		converted,
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Sint, float64(function, -7), .I8), ir.const_int(function, .I8, -7)),
	)
	converted = bool_and(function, converted, ir.compare(function, .FEq, high_float32, float32(function, f32(u64(1) << 63))))
	converted = bool_and(
		function,
		converted,
		ir.compare(function, .Eq, ir.convert(function, .Float_To_Uint, float32(function, f32(u64(1) << 63)), .I64), high),
	)
	converted = bool_and(function, converted, ir.compare(function, .FEq, widened, float64(function, 1.5)))
	converted = bool_and(function, converted, ir.compare(function, .FEq, ir.convert(function, .Float_Trunc, widened, .F32), float32(function, 1.5)))

	slot := ir.stack_slot(function, entry.control, 8, 8)
	slot32 := ir.stack_slot(function, entry.control, 4, 4)
	memory = ir.store(function, entry.control, memory, slot, float64(function, 6), 0)
	memory = ir.store(function, entry.control, memory, slot32, float32(function, 4), 0)
	loaded := ir.load(function, entry.control, memory, slot, .F64, 0)
	loaded32 := ir.load(function, entry.control, memory, slot32, .F32, 0)
	bits := ir.convert(function, .Bitcast, float32(function, 1), .I32)
	stored := bool_and(function, ir.compare(function, .FEq, loaded, float64(function, 6)), ir.compare(function, .FEq, loaded32, float32(function, 4)))
	stored = bool_and(function, stored, ir.compare(function, .Eq, bits, ir.const_int(function, .I32, 0x3f80_0000)))
	stored = bool_and(
		function,
		stored,
		ir.compare(function, .FEq, ir.convert(function, .Bitcast, ir.const_int(function, .I64, 0x4000_0000_0000_0000), .F64), two),
	)

	keep := ir.binary(function, .FAdd, float64(function, 10), float64(function, 0))
	arguments := []ir.Node_Id{ir.const_int(function, .I64, 20), one, one, one, one, one, one, one, one, keep, ir.const_int(function, .I64, 3)}
	call := ir.call(function, entry.control, memory, ir.symbol_addr(function, {space = .Function, index = 1}), callee_index, arguments)
	memory = ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	returned := ir.add_node(function, .Proj, .F64, {call}, {index = 1})
	// `keep` is an argument, so it is defined before the call, and adding it to the
	// result keeps it live across the call, which spills the caller-saved xmm.
	preserved := ir.binary(function, .FAdd, returned, keep)
	// 20 + 3 + eight 1s + the stacked 10, plus that same 10 added after the call.
	called := ir.compare(function, .Eq, ir.convert(function, .Float_To_Sint, preserved, .I64), ir.const_int(function, .I64, 51))

	score := ir.const_int(function, .I64, 0)
	score = score_bit(function, score, arithmetic, 1)
	score = score_bit(function, score, compared, 2)
	score = score_bit(function, score, selected, 4)
	score = score_bit(function, score, converted, 8)
	score = score_bit(function, score, stored, 16)
	score = score_bit(function, score, called, 32)
	exit_call := ir.add_node(function, .Syscall, .Tuple, {entry.control, memory, ir.const_int(function, .I64, 231), score})
	memory = ir.add_node(function, .Proj, .Memory, {exit_call}, {index = 0})
	ir.unreachable(function, entry.control, memory)
	testing.expect_value(t, ir.function_finish(function), nil)

	abi_parameters := make([]types.Abi_Param, len(callee_parameters))
	defer delete(abi_parameters)
	for parameter, index in callee_parameters {
		abi_parameters[index] = {
			type = .F64 if parameter.type == .F64 else .I64,
		}
	}
	selected_test_run(t, function, 63, callee, {convention = .C, params = abi_parameters, results = {{type = .F64}}})
}
