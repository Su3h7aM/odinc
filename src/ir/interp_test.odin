package ir

import "core:testing"

@(test)
interp_sums_to_n :: proc(t: ^testing.T) {
	fn, make_err := function_make(context.allocator, 0, "main.sum", 0)
	testing.expect_value(t, make_err, nil)
	defer function_destroy(fn)

	add_signature(fn, Signature{cc = .C, params = {{type = .I64}}, results = {{type = .I64}}})
	entry := start(fn)
	n := entry.params[0]
	b, builder_err := builder_make(context.allocator, fn, entry)
	testing.expect_value(t, builder_err, nil)
	defer builder_destroy(b)

	zero, one := const_int(fn, .I64, 0), const_int(fn, .I64, 1)
	i := variable_declare(b, one)
	sum := variable_declare(b, zero)

	exit_target := jump_target_make(b)
	loop := loop_begin(b, {i, sum})
	continue_target := jump_target_make(b)
	exit := branch_if(b, compare(fn, .SLe, variable_get(b, i), n))
	enter_arm(b, exit, 1)
	jump_to(b, exit_target)
	enter_arm(b, exit, 0)

	variable_set(b, sum, binary(fn, .Add, variable_get(b, sum), variable_get(b, i)))
	jump_to(b, continue_target)
	testing.expect(t, seal_target(b, continue_target))
	variable_set(b, i, binary(fn, .Add, variable_get(b, i), one))
	loop_end(b, loop)
	testing.expect(t, seal_target(b, exit_target))

	emit_return(b, variable_get(b, sum))
	testing.expect_value(t, builder_finish(b), nil)

	cases := [?]struct {
		n, sum: u64,
	}{{0, 0}, {1, 1}, {10, 55}, {100, 5050}}
	for c in cases {
		result, err := interp_run(fn, []u64{c.n}, 10_000, context.allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, result.outcome, Interp_Outcome.Value)
		testing.expect_value(t, result.value, c.sum)
	}
}

Edge_Case :: struct {
	kind:          Node_Kind,
	type:          Value_Type,
	count_type:    Value_Type,
	a, b:          u64,
	guard_divisor: bool,
	outcome:       Interp_Outcome,
	value:         u64,
}

@(private = "file")
edge_constant :: proc(fn: ^Function, type: Value_Type, bits_value: u64) -> Node_Id {
	if interp_is_float(type) {
		return const_float(fn, type, bits_value)
	}
	return const_int(fn, type, i64(bits_value))
}

@(private = "file")
edge_node :: proc(fn: ^Function, control: Node_Id, c: Edge_Case) -> Node_Id {
	a := edge_constant(fn, c.type, c.a)
	count_type := c.count_type if c.count_type != .None else c.type
	b := edge_constant(fn, count_type, c.b)
	#partial switch c.kind {
	case .SDiv, .UDiv, .SRem, .URem:
		divisor := b
		if c.guard_divisor {
			minus_one := const_int(fn, c.type, -1)
			divisor = select(fn, compare(fn, .Eq, b, minus_one), const_int(fn, c.type, 1), b)
		}
		return divide(fn, c.kind, control, a, divisor)
	case .Eq, .Ne, .SLt, .SLe, .ULt, .ULe, .FEq, .FLt, .FLe, .FNe:
		return compare(fn, c.kind, a, b)
	case .Clz, .Ctz, .Popcnt, .Bswap, .FNeg, .FSqrt:
		return unary(fn, c.kind, a)
	}
	return binary(fn, c.kind, a, b)
}

@(private = "file")
edge_result :: proc(t: ^testing.T, c: Edge_Case) -> Interp_Result {
	fn, make_err := function_make(context.allocator, 0, "main.edge", 0)
	testing.expect_value(t, make_err, nil)
	defer function_destroy(fn)

	result_type := c.type
	#partial switch c.kind {
	case .Eq, .Ne, .SLt, .SLe, .ULt, .ULe, .FEq, .FLt, .FLe, .FNe:
		result_type = .Bool
	}
	add_signature(fn, Signature{cc = .C, results = {{type = result_type}}})
	entry := start(fn)
	b, builder_err := builder_make(context.allocator, fn, entry)
	testing.expect_value(t, builder_err, nil)
	defer builder_destroy(b)

	result := edge_node(fn, entry.control, c)
	emit_return(b, result)
	testing.expect_value(t, builder_finish(b), nil)

	outcome, err := interp_run(fn, nil, 100, context.allocator)
	testing.expect_value(t, err, nil)
	return outcome
}

@(test)
interp_arithmetic_edges :: proc(t: ^testing.T) {
	cases := [?]Edge_Case {
		// Shifts: counts at or above the width, count read unsigned in its own width, arithmetic sign fill.
		{kind = .Shl, type = .I8, count_type = .I64, a = 0x81, b = 8, outcome = .Value, value = 0},
		{kind = .Shr, type = .I8, count_type = .I8, a = 0x80, b = 0xFF, outcome = .Value, value = 0},
		{kind = .Sar, type = .I8, count_type = .I64, a = 0x80, b = 8, outcome = .Value, value = 0xFF},
		{kind = .Sar, type = .I8, count_type = .I8, a = 0x80, b = 3, outcome = .Value, value = 0xF0},
		// Division: truncation toward zero, MIN / -1 and MIN % -1 trap at the hardware level, guard gives 0.
		{kind = .SDiv, type = .I8, a = 0xF9, b = 2, outcome = .Value, value = 0xFD},
		{kind = .SRem, type = .I8, a = 0xF9, b = 2, outcome = .Value, value = 0xFF},
		{kind = .UDiv, type = .I8, a = 0xFF, b = 2, outcome = .Value, value = 0x7F},
		{kind = .SDiv, type = .I8, a = 0x80, b = 0xFF, outcome = .Arith_Trap},
		{kind = .SRem, type = .I8, a = 0x80, b = 0xFF, outcome = .Arith_Trap},
		{kind = .SRem, type = .I8, a = 0x80, b = 0xFF, guard_divisor = true, outcome = .Value, value = 0},
		{kind = .SDiv, type = .I32, a = 7, b = 0, outcome = .Arith_Trap},
		// Integer wrap and signed versus unsigned compare.
		{kind = .Add, type = .I8, a = 0x7F, b = 1, outcome = .Value, value = 0x80},
		{kind = .SLt, type = .I8, a = 0xFF, b = 1, outcome = .Value, value = 1},
		{kind = .ULt, type = .I8, a = 0xFF, b = 1, outcome = .Value, value = 0},
		// Clz and Ctz of zero give the width.
		{kind = .Clz, type = .I32, a = 0, outcome = .Value, value = 32},
		{kind = .Ctz, type = .I8, a = 0, outcome = .Value, value = 8},
		// F32 addition rounds to 32 bits: 2^24 + 1 is 2^24.
		{kind = .FAdd, type = .F32, a = 0x4B800000, b = 0x3F800000, outcome = .Value, value = 0x4B800000},
	}
	for c in cases {
		result := edge_result(t, c)
		testing.expectf(
			t,
			result.outcome == c.outcome && result.value == c.value,
			"%v %v: got %v %x, want %v %x",
			c.kind,
			c.type,
			result.outcome,
			result.value,
			c.outcome,
			c.value,
		)
	}
}
