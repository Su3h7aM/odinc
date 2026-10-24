package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// The System V x86-64 `va_list` is {gp_offset: u32, fp_offset: u32, overflow_arg_area, reg_save_area}. The prologue of
// a C-variadic function stores the argument registers in the save area (see `lower_start`); `c_va_start` fills the
// list, and `c_va_arg` follows psABI 3.5.7: an argument whose eightbytes all fit in the registers still free is read from
// the save area, any other from the overflow area on the stack.
VA_LIST_GP_OFFSET :: 0
VA_LIST_FP_OFFSET :: 4
VA_LIST_OVERFLOW_AREA :: 8
VA_LIST_SAVE_AREA :: 16
VA_LIST_BYTES :: 24
VA_GP_LIMIT :: 48
VA_FP_LIMIT :: 176

@(private)
lower_c_varargs :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	function := state.job.function
	if len(plan.arguments) != 2 && !(kind == .C_Va_End && len(plan.arguments) == 1) || !call_operand_valid(state, plan.arguments[0]) {
		return lower_fail(state, node, .Builtin)
	}
	list := lower_operand(state, plan.arguments[0])
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[list] != .Ptr { return lower_fail(state, node, .Builtin) }
	#partial switch kind {
	case .C_Va_Start:
		lower_target_op(state, node, .C_Va_Start, {list}, nil)
		return 0
	case .C_Va_End:
		// The System V `va_list` owns no resources.
		return 0
	case .C_Va_Copy:
		if !call_operand_valid(state, plan.arguments[1]) { return lower_fail(state, node, .Builtin) }
		source := lower_operand(state, plan.arguments[1])
		if state.failed || function.error != nil { return 0 }
		return lower_memory_effect(state, .Mem_Copy, list, source, ir.const_int(function, .I64, VA_LIST_BYTES))
	}
	return lower_c_va_arg(state, node, info, list)
}

@(private)
Va_Classes :: struct {
	classes:   types.Classification,
	integers:  int,
	vectors:   int,
	in_memory: bool,
}

@(private)
va_arg_classes :: proc(state: ^Procedure_State, plan_id: check.Plan_Id, type: types.Type_Id) -> Va_Classes {
	scalar := scalar_type(state, type)
	result: Va_Classes
	if is_float16(state, type) || scalar == .F32 || scalar == .F64 {
		result.classes.count = 1
		result.classes.classes[0] = .SSE
	} else if scalar != .None {
		result.classes.count = 1
		result.classes.classes[0] = .Integer
	} else {
		result.classes = state.job.abi_plans.va_arg_classes[plan_id]
	}
	for index in 0 ..< int(result.classes.count) {
		#partial switch result.classes.classes[index] {
		case .Integer:
			result.integers += 1
		case .SSE:
			result.vectors += 1
		case .SSE_Up, .No_Class:
		case:
			result.in_memory = true
		}
	}
	return result
}

@(private)
lower_c_va_arg :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, list: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	builder := state.builder
	type := info.type
	layout := state.job.layouts[type]
	if type == 0 || layout.error != .None { return lower_fail(state, node, .Builtin) }
	classes := va_arg_classes(state, info.plan, type)
	scalar := scalar_type(state, type)
	slot_size := u32(max(align_to_word(layout.size), 8))
	slot_align := u32(max(layout.align, 8))
	slot := ir.stack_slot(function, state.entry_control, slot_size, min(slot_align, 16))
	variable_count := len(builder.values)
	address := ir.variable_declare(builder, ir.undef(function, .Ptr))
	if classes.in_memory || classes.classes.count == 0 {
		ir.variable_set(builder, address, slot)
		lower_va_copy_from_overflow(state, list, slot, layout)
	} else {
		end := ir.jump_target_make(builder)
		branch := ir.branch_if(builder, va_registers_available(state, list, classes))
		ir.enter_arm(builder, branch, 0)
		ir.variable_set(builder, address, lower_va_from_registers(state, list, slot, classes, scalar != .None))
		ir.jump_to(builder, end)
		ir.enter_arm(builder, branch, 1)
		ir.variable_set(builder, address, lower_va_from_overflow(state, list, slot, layout, scalar != .None))
		ir.jump_to(builder, end)
		ir.seal_target(builder, end)
	}
	result := ir.variable_get(builder, address)
	ir.variables_truncate(builder, variable_count)
	if scalar == .None { return slot }
	return lower_va_scalar(state, result, type, scalar)
}

@(private)
align_to_word :: proc(size: i64) -> i64 {
	return (size + 7) &~ 7
}

// A single-precision or half-precision argument was promoted to double by the caller.
@(private)
lower_va_scalar :: proc(state: ^Procedure_State, address: ir.Node_Id, type: types.Type_Id, scalar: ir.Value_Type) -> ir.Node_Id {
	function := state.job.function
	if is_float16(state, type) { return float16_narrow(function, lower_load_word(state, address, .F64)) }
	if scalar == .F32 { return ir.convert(function, .Float_Trunc, lower_load_word(state, address, .F64), .F32) }
	return lower_load(state, address, type)
}

@(private)
va_list_field :: proc(state: ^Procedure_State, list: ir.Node_Id, offset: i64, type: ir.Value_Type) -> ir.Node_Id {
	return lower_load_word(state, ir.ptr_offset(state.job.function, list, offset), type)
}

@(private)
va_registers_available :: proc(state: ^Procedure_State, list: ir.Node_Id, classes: Va_Classes) -> ir.Node_Id {
	function := state.job.function
	available := ir.const_int(function, .Bool, 1)
	if classes.integers != 0 {
		gp := va_list_field(state, list, VA_LIST_GP_OFFSET, .I32)
		available = ir.compare(function, .ULe, gp, ir.const_int(function, .I32, i64(VA_GP_LIMIT - 8 * classes.integers)))
	}
	if classes.vectors != 0 {
		fp := va_list_field(state, list, VA_LIST_FP_OFFSET, .I32)
		fits := ir.compare(function, .ULe, fp, ir.const_int(function, .I32, i64(VA_FP_LIMIT - 16 * classes.vectors)))
		available = fits if classes.integers == 0 else ir.binary(function, .And, available, fits)
	}
	return available
}

// Reads the eightbytes from the save area and advances the offsets. A scalar is read in place; an aggregate is
// gathered into `slot`, as its eightbytes may come from both register files.
@(private)
lower_va_from_registers :: proc(state: ^Procedure_State, list: ir.Node_Id, slot: ir.Node_Id, classes: Va_Classes, in_place: bool) -> ir.Node_Id {
	function := state.job.function
	save_area := va_list_field(state, list, VA_LIST_SAVE_AREA, .Ptr)
	gp := va_list_field(state, list, VA_LIST_GP_OFFSET, .I32)
	fp := va_list_field(state, list, VA_LIST_FP_OFFSET, .I32)
	next_integer := ir.ptr_index(function, save_area, ir.convert(function, .Zext, gp, .I64), 1)
	next_vector := ir.ptr_index(function, save_area, ir.convert(function, .Zext, fp, .I64), 1)
	first: ir.Node_Id
	previous: ir.Node_Id
	integers, vectors := 0, 0
	for index in 0 ..< int(classes.classes.count) {
		source: ir.Node_Id
		#partial switch classes.classes.classes[index] {
		case .Integer:
			source = ir.ptr_offset(function, next_integer, i64(8 * integers))
			integers += 1
		case .SSE:
			source = ir.ptr_offset(function, next_vector, i64(16 * vectors))
			vectors += 1
		case .SSE_Up:
			source = ir.ptr_offset(function, previous, 8)
		}
		previous = source
		if index == 0 { first = source }
		if in_place { continue }
		lower_store_word(state, ir.ptr_offset(function, slot, i64(8 * index)), lower_load_word(state, source, .I64))
	}
	if classes.integers != 0 {
		lower_store_word(
			state,
			ir.ptr_offset(function, list, VA_LIST_GP_OFFSET),
			ir.binary(function, .Add, gp, ir.const_int(function, .I32, i64(8 * classes.integers))),
		)
	}
	if classes.vectors != 0 {
		lower_store_word(
			state,
			ir.ptr_offset(function, list, VA_LIST_FP_OFFSET),
			ir.binary(function, .Add, fp, ir.const_int(function, .I32, i64(16 * classes.vectors))),
		)
	}
	return first if in_place else slot
}

@(private)
lower_va_from_overflow :: proc(state: ^Procedure_State, list: ir.Node_Id, slot: ir.Node_Id, layout: Type_Layout, in_place: bool) -> ir.Node_Id {
	if in_place { return lower_va_advance_overflow(state, list, layout) }
	lower_va_copy_from_overflow(state, list, slot, layout)
	return slot
}

// Takes the next stack argument: aligned to its alignment (at least eight), then past its size rounded up to eight.
@(private)
lower_va_advance_overflow :: proc(state: ^Procedure_State, list: ir.Node_Id, layout: Type_Layout) -> ir.Node_Id {
	function := state.job.function
	overflow := va_list_field(state, list, VA_LIST_OVERFLOW_AREA, .Ptr)
	if layout.align > 8 {
		mask := ir.const_int(function, .I64, layout.align - 1)
		rounded := ir.binary(
			function,
			.And,
			ir.binary(function, .Add, ir.convert(function, .Bitcast, overflow, .I64), mask),
			ir.const_int(function, .I64, -layout.align),
		)
		overflow = ir.convert(function, .Bitcast, rounded, .Ptr)
	}
	lower_store_word(state, ir.ptr_offset(function, list, VA_LIST_OVERFLOW_AREA), ir.ptr_offset(function, overflow, align_to_word(layout.size)))
	return overflow
}

@(private)
lower_va_copy_from_overflow :: proc(state: ^Procedure_State, list: ir.Node_Id, slot: ir.Node_Id, layout: Type_Layout) {
	function := state.job.function
	source := lower_va_advance_overflow(state, list, layout)
	if layout.size > 0 { lower_memory_effect(state, .Mem_Copy, slot, source, ir.const_int(function, .I64, layout.size)) }
}
