package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A `#simd` value is the address of a stack slot holding its lanes, as an aggregate is. Each lane is one scalar
// access, so the interpreter and every backend see only scalar nodes.
@(private)
lower_simd_builtin :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> (
	value: ir.Node_Id,
	handled: bool,
) {
	#partial switch kind {
	case .Unaligned_Load, .Simd_Indices, .Simd_Select, .Simd_Lanes_Ne, .Simd_Reduce_Or, .Simd_Reduce_Min:
		return lower_simd_operation(state, node, info, plan, kind), true
	}
	return 0, false
}

@(private)
lower_simd_operation :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	if info.type == 0 { return lower_fail(state, node, .Builtin) }
	values, ok := lower_intrinsic_operands(state, node, plan)
	if !ok { return 0 }
	function := state.job.function
	#partial switch kind {
	case .Unaligned_Load:
		if len(plan.arguments) != 1 || function.nodes.type[values[0]] != .Ptr { return lower_fail(state, node, .Builtin) }
		if scalar_type(state, info.type) != .None { return lower_load(state, values[0], info.type) }
		copy := simd_slot(state, info.type)
		lower_store(state, copy, values[0], info.type)
		return copy
	case .Simd_Indices:
		if len(plan.arguments) != 0 { return lower_fail(state, node, .Builtin) }
		return lower_simd_indices(state, node, info.type)
	case .Simd_Select:
		if len(plan.arguments) != 3 { return lower_fail(state, node, .Builtin) }
		return lower_simd_select(state, info.type, operand_type(state, plan.arguments[0]), values)
	case .Simd_Lanes_Ne:
		if len(plan.arguments) != 2 { return lower_fail(state, node, .Builtin) }
		return lower_simd_lanes_ne(state, info.type, operand_type(state, plan.arguments[0]), values)
	case .Simd_Reduce_Or, .Simd_Reduce_Min:
		if len(plan.arguments) != 1 { return lower_fail(state, node, .Builtin) }
		return lower_simd_reduce(state, node, kind, operand_type(state, plan.arguments[0]), values[0])
	}
	return lower_fail(state, node, .Builtin)
}

@(private)
lower_simd_indices :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	lane_type := scalar_type(state, elem)
	if !is_integer_type(lane_type) && lane_type != .F32 && lane_type != .F64 { return lower_fail(state, node, .Builtin) }
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		lower_store(state, simd_lane_address(state, address, lane, elem), simd_lane_index(function, lane_type, lane), elem)
	}
	return address
}

@(private)
simd_lane_index :: proc(function: ^ir.Function, lane_type: ir.Value_Type, lane: i64) -> ir.Node_Id {
	#partial switch lane_type {
	case .F32:
		return ir.const_float(function, lane_type, u64(transmute(u32)f32(lane)))
	case .F64:
		return ir.const_float(function, lane_type, transmute(u64)f64(lane))
	}
	return ir.const_int(function, lane_type, lane)
}

@(private)
lower_simd_select :: proc(state: ^Procedure_State, type, mask_type: types.Type_Id, values: [5]ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	mask_elem, _ := simd_shape(state, mask_type)
	mask_is_bool := lower_type(state, mask_elem).kind == .Bool
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		condition := simd_lane_value(state, values[0], lane, mask_elem)
		if !mask_is_bool {
			condition = ir.compare(function, .Ne, condition, ir.const_int(function, scalar_type(state, mask_elem), 0))
		}
		chosen := ir.select(function, condition, simd_lane_value(state, values[1], lane, elem), simd_lane_value(state, values[2], lane, elem))
		lower_store(state, simd_lane_address(state, address, lane, elem), chosen, elem)
	}
	return address
}

@(private)
lower_simd_lanes_ne :: proc(state: ^Procedure_State, type, operand: types.Type_Id, values: [5]ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	input_elem, lanes := simd_shape(state, operand)
	output_elem, _ := simd_shape(state, type)
	compare_kind := ir.Node_Kind.FNe if lower_type(state, input_elem).kind == .Float else .Ne
	lane_type := scalar_type(state, output_elem)
	all_ones := ir.const_int(function, lane_type, -1)
	none := ir.const_int(function, lane_type, 0)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		different := ir.compare(
			function,
			compare_kind,
			simd_lane_value(state, values[0], lane, input_elem),
			simd_lane_value(state, values[1], lane, input_elem),
		)
		lower_store(state, simd_lane_address(state, address, lane, output_elem), ir.select(function, different, all_ones, none), output_elem)
	}
	return address
}

@(private)
lower_simd_reduce :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	kind: check.Builtin_Kind,
	vector_type: types.Type_Id,
	vector: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, vector_type)
	floating := lower_type(state, elem).kind == .Float
	less_kind := ir.Node_Kind.SLt if signed_type(state, elem) else ir.Node_Kind.ULt
	accumulator := simd_lane_value(state, vector, 0, elem)
	for lane in 1 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		next := simd_lane_value(state, vector, lane, elem)
		if kind == .Simd_Reduce_Or {
			accumulator = ir.binary(function, .Or, accumulator, next)
		} else if floating {
			accumulator = pick_minnum(function, accumulator, next)
		} else {
			accumulator = pick_ordered(function, less_kind, accumulator, next, true)
		}
	}
	return accumulator
}

// Floating minimum with `fmin` semantics, as llvm.vector.reduce.fmin: a NaN operand yields the other one.
@(private)
pick_minnum :: proc(function: ^ir.Function, accumulator, next: ir.Node_Id) -> ir.Node_Id {
	next_less := ir.compare(function, .FLt, next, accumulator)
	accumulator_nan := ir.compare(function, .FNe, accumulator, accumulator)
	choose_next := ir.binary(function, .Or, next_less, accumulator_nan)
	lane_type := function.nodes.type[accumulator]
	integer_type := ir.Value_Type.I16 if lane_type == .F16 else ir.Value_Type.I32 if lane_type == .F32 else ir.Value_Type.I64
	zero := ir.const_float(function, lane_type, 0)
	accumulator_zero := ir.compare(function, .FEq, accumulator, zero)
	next_zero := ir.compare(function, .FEq, next, zero)
	next_sign := ir.convert(function, .Bitcast, next, integer_type)
	next_negative := ir.compare(function, .SLt, next_sign, ir.const_int(function, integer_type, 0))
	negative_zero_preference := ir.binary(function, .And, accumulator_zero, ir.binary(function, .And, next_zero, next_negative))
	choose_next = ir.binary(function, .Or, choose_next, negative_zero_preference)
	return ir.select(function, choose_next, next, accumulator)
}

// Broadcast of a typed scalar into every lane, from `lower_conversion`.
@(private)
lower_simd_broadcast :: proc(state: ^Procedure_State, type: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	elem, lanes := simd_shape(state, type)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || state.job.function.error != nil { return 0 }
		lower_store(state, simd_lane_address(state, address, lane, elem), value, elem)
	}
	return address
}

@(private)
simd_shape :: proc(state: ^Procedure_State, type: types.Type_Id) -> (elem: types.Type_Id, lanes: i64) {
	descriptor := lower_type(state, type)
	return descriptor.elem, descriptor.count
}

@(private)
simd_slot :: proc(state: ^Procedure_State, type: types.Type_Id) -> ir.Node_Id {
	layout := state.job.layouts[type]
	return ir.stack_slot(state.job.function, state.entry_control, u32(layout.size), u32(layout.align))
}

@(private)
simd_lane_address :: proc(state: ^Procedure_State, vector: ir.Node_Id, lane: i64, elem: types.Type_Id) -> ir.Node_Id {
	return ir.ptr_offset(state.job.function, vector, lane * state.job.layouts[elem].size)
}

@(private)
simd_lane_value :: proc(state: ^Procedure_State, vector: ir.Node_Id, lane: i64, elem: types.Type_Id) -> ir.Node_Id {
	return lower_load(state, simd_lane_address(state, vector, lane, elem), elem)
}
