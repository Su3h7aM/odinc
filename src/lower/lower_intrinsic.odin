package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// Lowers the intrinsics of base:intrinsics planned by the checker. Operands arrive already converted to the
// types the checker fixed; each shape is validated here before its node is built.
@(private)
lower_intrinsic :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	for operand in plan.arguments {
		if !call_operand_valid(state, operand) { return lower_fail(state, node, .Builtin) }
	}
	function := state.job.function
	values: [3]ir.Node_Id
	for operand, index in plan.arguments {
		values[index] = lower_operand(state, operand)
		if state.failed || function.error != nil { return 0 }
	}
	type := ir.Value_Type.None
	if info.type != 0 { type = scalar_type(state, info.type) }
	#partial switch kind {
	case .Count_Ones, .Count_Zeros, .Count_Leading_Zeros, .Count_Trailing_Zeros, .Reverse_Bits, .Byte_Swap:
		if !is_integer_value(function, values[0]) || type != function.nodes.type[values[0]] { return lower_fail(state, node, .Builtin) }
		return lower_bit_intrinsic(state, kind, values[0])
	case .Expect:
		if type != function.nodes.type[values[0]] || type != function.nodes.type[values[1]] { return lower_fail(state, node, .Builtin) }
		return values[0]
	case .Volatile_Load, .Atomic_Load:
		order := ir.Memory_Order.Volatile if kind == .Volatile_Load else .Seq_Cst
		if !is_integer_type(type) || function.nodes.type[values[0]] != .Ptr { return lower_fail(state, node, .Builtin) }
		return lower_ordered_load(state, values[0], type, order)
	case .Volatile_Store, .Atomic_Store:
		order := ir.Memory_Order.Volatile if kind == .Volatile_Store else .Seq_Cst
		if function.nodes.type[values[0]] != .Ptr || !is_integer_value(function, values[1]) { return lower_fail(state, node, .Builtin) }
		memory := ir.add_node(
			function,
			.Store,
			.Memory,
			{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), values[0], values[1]},
			{access = {order = order}},
		)
		ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
		return 0
	case .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Exchange:
		if function.nodes.type[values[0]] != .Ptr || !is_integer_value(function, values[1]) || function.nodes.type[values[1]] != type {
			return lower_fail(state, node, .Builtin)
		}
		return lower_read_modify_write(state, rmw_operation(kind), values[0], values[1], type)
	case .Mem_Copy, .Mem_Copy_Non_Overlapping:
		if function.nodes.type[values[0]] != .Ptr || function.nodes.type[values[1]] != .Ptr || function.nodes.type[values[2]] != .I64 {
			return lower_fail(state, node, .Builtin)
		}
		return lower_memory_effect(state, .Mem_Copy, values[0], values[1], values[2])
	case .Mem_Zero:
		if function.nodes.type[values[0]] != .Ptr || function.nodes.type[values[1]] != .I64 { return lower_fail(state, node, .Builtin) }
		zero := ir.const_int(function, .I8, 0)
		return lower_memory_effect(state, .Mem_Set, values[0], zero, values[1])
	}
	return lower_fail(state, node, .Builtin)
}

@(private)
is_integer_value :: proc(function: ^ir.Function, value: ir.Node_Id) -> bool {
	return is_integer_type(function.nodes.type[value])
}

@(private)
is_integer_type :: proc(type: ir.Value_Type) -> bool {
	return type >= .I8 && type <= .I64
}

@(private)
rmw_operation :: proc(kind: check.Builtin_Kind) -> ir.Rmw_Op {
	#partial switch kind {
	case .Atomic_Add:
		return .Add
	case .Atomic_Sub:
		return .Sub
	case .Atomic_And:
		return .And
	case .Atomic_Or:
		return .Or
	case .Atomic_Xor:
		return .Xor
	}
	return .Xchg
}

@(private)
lower_bit_intrinsic :: proc(state: ^Procedure_State, kind: check.Builtin_Kind, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	type := function.nodes.type[value]
	#partial switch kind {
	case .Count_Ones:
		return ir.unary(function, .Popcnt, value)
	case .Count_Zeros:
		ones := ir.unary(function, .Popcnt, value)
		return ir.binary(function, .Sub, ir.const_int(function, type, i64(scalar_bits(type))), ones)
	case .Count_Leading_Zeros:
		return ir.unary(function, .Clz, value)
	case .Count_Trailing_Zeros:
		return ir.unary(function, .Ctz, value)
	case .Byte_Swap:
		if type == .I8 { return value }
		return ir.unary(function, .Bswap, value)
	}
	return lower_reverse_bits(state, value)
}

// Swaps adjacent bits, then pairs, then nibbles, then reverses the bytes (SWAR, as the fork's bit-reversal expansion).
@(private)
lower_reverse_bits :: proc(state: ^Procedure_State, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	type := function.nodes.type[value]
	steps := [3]struct {
		shift: i64,
		mask:  i64,
	}{{1, 0x5555555555555555}, {2, 0x3333333333333333}, {4, 0x0f0f0f0f0f0f0f0f}}
	result := value
	for step in steps {
		count := ir.const_int(function, .I8, step.shift)
		mask := ir.const_int(function, type, step.mask)
		high := ir.binary(function, .And, ir.binary(function, .Shr, result, count), mask)
		low := ir.binary(function, .Shl, ir.binary(function, .And, result, mask), count)
		result = ir.binary(function, .Or, high, low)
	}
	if type == .I8 { return result }
	return ir.unary(function, .Bswap, result)
}

@(private)
lower_ordered_load :: proc(state: ^Procedure_State, pointer: ir.Node_Id, type: ir.Value_Type, order: ir.Memory_Order) -> ir.Node_Id {
	function := state.job.function
	load := ir.add_node(
		function,
		.Load_Ordered,
		.Tuple,
		{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), pointer},
		{access = {order = order, value_type = type}},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, ir.add_node(function, .Proj, .Memory, {load}, {index = 0}))
	return ir.add_node(function, .Proj, type, {load}, {index = 1})
}

// The result is the old value. Sequentially consistent, as the Odin intrinsics without an explicit order.
@(private)
lower_read_modify_write :: proc(state: ^Procedure_State, operation: ir.Rmw_Op, pointer, operand: ir.Node_Id, type: ir.Value_Type) -> ir.Node_Id {
	function := state.job.function
	update := ir.add_node(
		function,
		.Atomic_Rmw,
		.Tuple,
		{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), pointer, operand},
		{access = {order = .Seq_Cst, rmw = operation}},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, ir.add_node(function, .Proj, .Memory, {update}, {index = 0}))
	return ir.add_node(function, .Proj, type, {update}, {index = 1})
}

@(private)
lower_memory_effect :: proc(state: ^Procedure_State, kind: ir.Node_Kind, destination, source_or_byte, size: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	memory := ir.add_node(
		function,
		kind,
		.Memory,
		{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), destination, source_or_byte, size},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	return 0
}
