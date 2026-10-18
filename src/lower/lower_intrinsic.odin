package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// Lowers the intrinsics of base:intrinsics planned by the checker. Operands arrive already converted to the
// types the checker fixed; each shape is validated here before its node is built. Intrinsics with two results
// go through `lower_intrinsic_tuple`, and the single-value entry takes their first result.
@(private)
lower_intrinsic :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	if len(plan.results) != 0 {
		results: [4]ir.Node_Id
		lower_intrinsic_tuple(state, node, plan, kind, results[:])
		return results[0]
	}
	values, ok := lower_intrinsic_operands(state, node, plan)
	if !ok { return 0 }
	function := state.job.function
	arguments := values[:len(plan.arguments)]
	type := ir.Value_Type.None
	if info.type != 0 { type = scalar_type(state, info.type) }
	order, order_ok := intrinsic_memory_order(state, node, kind, arguments)
	if !order_ok { return 0 }
	#partial switch kind {
	case .Unaligned_Store:
		if len(plan.arguments) != 2 || function.nodes.type[values[0]] != .Ptr { return lower_fail(state, node, .Builtin) }
		pointer := lower_type(state, operand_type(state, plan.arguments[0]))
		lower_store(state, values[0], values[1], pointer.elem)
		return 0
	case .Count_Ones, .Count_Zeros, .Count_Leading_Zeros, .Count_Trailing_Zeros, .Reverse_Bits, .Byte_Swap:
		if !is_integer_value(function, values[0]) || type != function.nodes.type[values[0]] { return lower_fail(state, node, .Builtin) }
		return lower_bit_intrinsic(state, kind, values[0])
	case .Read_Cycle_Counter:
		results: [1]ir.Node_Id
		lower_target_op(state, node, .Rdtsc, nil, results[:])
		return results[0]
	case .Expect:
		if type != function.nodes.type[values[0]] || type != function.nodes.type[values[1]] { return lower_fail(state, node, .Builtin) }
		return values[0]
	case .Volatile_Load, .Atomic_Load, .Atomic_Load_Explicit:
		if !is_atomic_type(type) || function.nodes.type[values[0]] != .Ptr { return lower_fail(state, node, .Builtin) }
		return lower_ordered_load(state, values[0], type, order)
	case .Volatile_Store, .Atomic_Store, .Atomic_Store_Explicit:
		if function.nodes.type[values[0]] != .Ptr || !is_atomic_type(function.nodes.type[values[1]]) { return lower_fail(state, node, .Builtin) }
		memory := ir.add_node(
			function,
			.Store,
			.Memory,
			{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), values[0], values[1]},
			{access = {order = order}},
		)
		ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
		return 0
	case .Atomic_Add,
	     .Atomic_Sub,
	     .Atomic_And,
	     .Atomic_Nand,
	     .Atomic_Or,
	     .Atomic_Xor,
	     .Atomic_Exchange,
	     .Atomic_Add_Explicit,
	     .Atomic_Sub_Explicit,
	     .Atomic_And_Explicit,
	     .Atomic_Nand_Explicit,
	     .Atomic_Or_Explicit,
	     .Atomic_Xor_Explicit,
	     .Atomic_Exchange_Explicit:
		if function.nodes.type[values[0]] != .Ptr || !is_integer_value(function, values[1]) || function.nodes.type[values[1]] != type {
			return lower_fail(state, node, .Builtin)
		}
		return lower_read_modify_write(state, rmw_operation(kind), values[0], values[1], type, order)
	case .Atomic_Thread_Fence, .Atomic_Signal_Fence:
		memory := ir.add_node(
			function,
			.Fence,
			.Memory,
			{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE)},
			{access = {order = order, signal = kind == .Atomic_Signal_Fence}},
		)
		ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
		return 0
	case .Mem_Copy, .Mem_Copy_Non_Overlapping:
		if function.nodes.type[values[0]] != .Ptr || function.nodes.type[values[1]] != .Ptr || function.nodes.type[values[2]] != .I64 {
			return lower_fail(state, node, .Builtin)
		}
		return lower_memory_effect(state, .Mem_Copy, values[0], values[1], values[2])
	case .Mem_Zero:
		if function.nodes.type[values[0]] != .Ptr || function.nodes.type[values[1]] != .I64 { return lower_fail(state, node, .Builtin) }
		zero := ir.const_int(function, .I8, 0)
		return lower_memory_effect(state, .Mem_Set, values[0], zero, values[1])
	case .Sqrt:
		if !is_float_type(type) || type != function.nodes.type[values[0]] { return lower_fail(state, node, .Builtin) }
		return ir.unary(function, .FSqrt, values[0])
	case .Ptr_Offset:
		if function.nodes.type[values[0]] != .Ptr || !is_integer_value(function, values[1]) { return lower_fail(state, node, .Builtin) }
		pointer := lower_type(state, operand_type(state, plan.arguments[0]))
		layout := state.job.layouts[pointer.elem]
		if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
		offset := values[1]
		if function.nodes.type[offset] != .I64 {
			offset = ir.convert(function, .Sext if signed_type(state, operand_type(state, plan.arguments[1])) else .Zext, offset, .I64)
		}
		return ir.ptr_index(function, values[0], offset, u32(layout.size))
	case .Ptr_Sub:
		if function.nodes.type[values[0]] != .Ptr || function.nodes.type[values[1]] != .Ptr { return lower_fail(state, node, .Builtin) }
		pointer := lower_type(state, operand_type(state, plan.arguments[0]))
		layout := state.job.layouts[pointer.elem]
		if layout.error != .None || layout.size <= 0 || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
		first := ir.convert(function, .Bitcast, values[0], .I64)
		second := ir.convert(function, .Bitcast, values[1], .I64)
		difference := ir.binary(function, .Sub, first, second)
		return ir.divide(function, .SDiv, state.builder.control, difference, ir.const_int(function, .I64, layout.size))
	case .Entry_Point:
		lower_entry_point_call(state, node)
		return 0
	}
	return lower_fail(state, node, .Builtin)
}

// Fills the two results of an overflow or compare-exchange intrinsic: the value and the bool, in that order.
@(private)
lower_intrinsic_tuple :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan, kind: check.Builtin_Kind, results: []ir.Node_Id) {
	values, ok := lower_intrinsic_operands(state, node, plan)
	if !ok { return }
	function := state.job.function
	arguments := values[:len(plan.arguments)]
	#partial switch kind {
	case .Overflow_Add, .Overflow_Sub, .Overflow_Mul:
		if !is_integer_value(function, values[0]) || function.nodes.type[values[1]] != function.nodes.type[values[0]] {
			lower_fail(state, node, .Builtin)
			return
		}
		results[0], results[1] = lower_overflow(state, kind, signed_type(state, plan.results[0]), values[0], values[1])
	case .X86_Cpuid:
		lower_target_op(state, node, .Cpuid, arguments, results)
	case .X86_Xgetbv:
		lower_target_op(state, node, .Xgetbv, arguments, results)
	case .Atomic_Compare_Exchange_Strong, .Atomic_Compare_Exchange_Weak, .Atomic_Compare_Exchange_Strong_Explicit, .Atomic_Compare_Exchange_Weak_Explicit:
		success, success_ok := intrinsic_memory_order(state, node, kind, arguments)
		if !success_ok { return }
		failure := success
		if len(arguments) > 3 {
			failure, success_ok = atomic_memory_order(state, node, arguments[len(arguments) - 1])
			if !success_ok { return }
		}
		if function.nodes.type[values[0]] != .Ptr ||
		   !is_integer_value(function, values[1]) ||
		   function.nodes.type[values[2]] != function.nodes.type[values[1]] {
			lower_fail(state, node, .Builtin)
			return
		}
		weak := kind == .Atomic_Compare_Exchange_Weak || kind == .Atomic_Compare_Exchange_Weak_Explicit
		results[0], results[1] = lower_compare_exchange(state, values[0], values[1], values[2], success, failure, weak)
	case:
		lower_fail(state, node, .Builtin)
	}
}

@(private)
lower_intrinsic_operands :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan) -> (values: [5]ir.Node_Id, ok: bool) {
	for operand in plan.arguments {
		if !call_operand_valid(state, operand) {
			lower_fail(state, node, .Builtin)
			return values, false
		}
	}
	for operand, index in plan.arguments {
		values[index] = lower_operand(state, operand)
		if state.failed || state.job.function.error != nil { return values, false }
	}
	return values, true
}

// The order of a single-order operation, `Volatile` for volatile accesses and sequentially consistent otherwise.
// A compare-exchange's success order is its third-from-last operand, when its orders are explicit.
@(private)
intrinsic_memory_order :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	kind: check.Builtin_Kind,
	arguments: []ir.Node_Id,
) -> (
	ir.Memory_Order,
	bool,
) {
	#partial switch kind {
	case .Volatile_Load, .Volatile_Store:
		return .Volatile, true
	case .Atomic_Compare_Exchange_Strong_Explicit, .Atomic_Compare_Exchange_Weak_Explicit:
		return atomic_memory_order(state, node, arguments[len(arguments) - 2])
	case .Atomic_Load_Explicit,
	     .Atomic_Store_Explicit,
	     .Atomic_Add_Explicit,
	     .Atomic_Sub_Explicit,
	     .Atomic_And_Explicit,
	     .Atomic_Nand_Explicit,
	     .Atomic_Or_Explicit,
	     .Atomic_Xor_Explicit,
	     .Atomic_Exchange_Explicit,
	     .Atomic_Thread_Fence,
	     .Atomic_Signal_Fence:
		return atomic_memory_order(state, node, arguments[len(arguments) - 1])
	}
	return .Seq_Cst, true
}

// Maps the `Atomic_Memory_Order` constant to the IR order. Consume is monotonic, which the IR calls Relaxed.
@(private)
atomic_memory_order :: proc(state: ^Procedure_State, node: syntax.Node_Index, value: ir.Node_Id) -> (ir.Memory_Order, bool) {
	function := state.job.function
	if function.nodes.kind[value] == .Const_Int {
		switch ir.node_int_value(function, value) {
		case 0, 1:
			return .Relaxed, true
		case 2:
			return .Acquire, true
		case 3:
			return .Release, true
		case 4:
			return .Acq_Rel, true
		case 5:
			return .Seq_Cst, true
		}
	}
	lower_fail(state, node, .Builtin)
	return .Seq_Cst, false
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
is_atomic_type :: proc(type: ir.Value_Type) -> bool {
	return is_integer_type(type) || type == .Ptr
}

@(private)
is_float_type :: proc(type: ir.Value_Type) -> bool {
	return type == .F32 || type == .F64
}

@(private)
rmw_operation :: proc(kind: check.Builtin_Kind) -> ir.Rmw_Op {
	#partial switch kind {
	case .Atomic_Add, .Atomic_Add_Explicit:
		return .Add
	case .Atomic_Sub, .Atomic_Sub_Explicit:
		return .Sub
	case .Atomic_And, .Atomic_And_Explicit:
		return .And
	case .Atomic_Nand, .Atomic_Nand_Explicit:
		return .Nand
	case .Atomic_Or, .Atomic_Or_Explicit:
		return .Or
	case .Atomic_Xor, .Atomic_Xor_Explicit:
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

// The result is the old value.
@(private)
lower_read_modify_write :: proc(
	state: ^Procedure_State,
	operation: ir.Rmw_Op,
	pointer, operand: ir.Node_Id,
	type: ir.Value_Type,
	order: ir.Memory_Order,
) -> ir.Node_Id {
	function := state.job.function
	update := ir.add_node(
		function,
		.Atomic_Rmw,
		.Tuple,
		{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), pointer, operand},
		{access = {order = order, rmw = operation}},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, ir.add_node(function, .Proj, .Memory, {update}, {index = 0}))
	return ir.add_node(function, .Proj, type, {update}, {index = 1})
}

// Returns the old value and the success flag.
@(private)
lower_compare_exchange :: proc(
	state: ^Procedure_State,
	pointer, expected, desired: ir.Node_Id,
	success, failure: ir.Memory_Order,
	weak: bool,
) -> (
	old, succeeded: ir.Node_Id,
) {
	function := state.job.function
	type := function.nodes.type[expected]
	exchange := ir.add_node(
		function,
		.Atomic_Cas,
		.Tuple,
		{state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), pointer, expected, desired},
		{access = {order = success, failure_order = failure, weak = weak}},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, ir.add_node(function, .Proj, .Memory, {exchange}, {index = 0}))
	old = ir.add_node(function, .Proj, type, {exchange}, {index = 1})
	succeeded = ir.add_node(function, .Proj, .Bool, {exchange}, {index = 2})
	return
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
