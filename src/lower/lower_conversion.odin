package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_conversion :: proc(state: ^Procedure_State, plan: check.Conversion_Plan, node: syntax.Node_Index) -> ir.Node_Id {
	assert(plan.kind != .Invalid, "missing checked conversion kind")
	source_id := operand_type(state, plan.source)
	if state.failed { return 0 }
	constant_target := types.Type_Id(0)
	if types.is_untyped(check.type_store(state.job.program), source_id) { constant_target = plan.target }
	value := lower_operand(state, plan.source, constant_target)
	if state.failed { return 0 }
	return lower_conversion_value(state, plan, node, source_id, value)
}

@(private)
lower_conversion_value :: proc(
	state: ^Procedure_State,
	plan: check.Conversion_Plan,
	node: syntax.Node_Index,
	source_id: types.Type_Id,
	initial_value: ir.Node_Id,
) -> ir.Node_Id {
	value := initial_value
	if plan.kind == .Box { return lower_box_value(state, node, source_id, value) }
	if plan.kind == .Union_Injection || len(plan.path) != 0 { return lower_fail(state, node, .Conversion) }
	if scalar_type(state, source_id) != .None && lower_type(state, plan.target).kind == .Simd_Vector {
		return lower_simd_broadcast(state, plan.target, value)
	}
	function := state.job.function
	if is_wide_integer(state, plan.target) || is_wide_integer(state, source_id) {
		return lower_wide_conversion(state, node, source_id, plan.target, value)
	}
	if plan.kind == .Transmute && (scalar_type(state, source_id) == .None) != (scalar_type(state, plan.target) == .None) {
		return lower_transmute_across_classes(state, source_id, plan.target, value)
	}
	if scalar_type(state, plan.target) == .None { return lower_same_layout_conversion(state, node, plan, source_id, value) }
	source := function.nodes.type[value]
	target := scalar_type(state, plan.target)
	if source == target { return value }
	if target == .None { return lower_fail(state, node, .Conversion) }
	if plan.kind == .Transmute {
		return ir.convert(function, .Bitcast, value, target)
	}
	source_signed := signed_type(state, source_id)
	if source == .Ptr || target == .Ptr {
		if source != .I64 && source != .Ptr || target != .I64 && target != .Ptr { return lower_fail(state, node, .Conversion) }
		return ir.convert(function, .Bitcast, value, target)
	}
	source_bits := scalar_bits(source)
	target_bits := scalar_bits(target)
	if source == .F16 {
		value = float16_widen(function, value)
		source = .F32
	}
	if target == .F16 {
		wide := value
		#partial switch source {
		case .F32:
			wide = ir.convert(function, .Float_Ext, value, .F64)
		case .F64:
		case:
			if source < .I8 || source > .I64 { return lower_fail(state, node, .Conversion) }
			wide = ir.convert(function, .Sint_To_Float if source_signed else .Uint_To_Float, value, .F64)
		}
		return float16_narrow(function, wide)
	}
	source_bits = scalar_bits(source)
	if source >= .I8 && source <= .I64 && target >= .I8 && target <= .I64 {
		if source_bits > target_bits { return ir.convert(function, .Trunc, value, target) }
		kind := ir.Node_Kind.Sext if source_signed else ir.Node_Kind.Zext
		return ir.convert(function, kind, value, target)
	}
	if source == .F32 || source == .F64 {
		if target == .F32 || target == .F64 {
			return ir.convert(function, .Float_Ext if source_bits < target_bits else .Float_Trunc, value, target)
		}
		if target >= .I8 && target <= .I64 {
			return ir.convert(function, .Float_To_Sint if signed_type(state, plan.target) else .Float_To_Uint, value, target)
		}
	}
	if source >= .I8 && source <= .I64 && (target == .F32 || target == .F64) {
		return ir.convert(function, .Sint_To_Float if source_signed else .Uint_To_Float, value, target)
	}
	return lower_fail(state, node, .Conversion)
}

// `any(value)`: a stack copy of the value, and an `any` slot holding its data pointer and typeid.
@(private)
lower_box_value :: proc(state: ^Procedure_State, node: syntax.Node_Index, source_id: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	source_layout := state.job.layouts[source_id]
	if source_layout.error != .None { return lower_fail(state, node, .Conversion) }
	function := state.job.function
	data := ir.stack_slot(function, state.entry_control, u32(max(source_layout.size, 1)), u32(source_layout.align))
	lower_store(state, data, value, source_id)
	typeid_value := lower_runtime_typeid(state, node, source_id)
	if state.failed { return 0 }
	any_slot := ir.stack_slot(function, state.entry_control, 16, 8)
	lower_store_word(state, any_slot, data)
	lower_store_word(state, ir.ptr_offset(function, any_slot, 8), typeid_value)
	return any_slot
}

@(private)
scalar_bits :: proc(type: ir.Value_Type) -> int {
	#partial switch type {
	case .Bool:
		return 1
	case .I8:
		return 8
	case .I16, .F16:
		return 16
	case .I32, .F32:
		return 32
	case .I64, .F64, .Ptr:
		return 64
	case:
		return 0
	}
}

// Copies an aggregate operand (its address) into a fresh slot of the target type, for casts such as []u8 <-> string.
// Transmute between a scalar and an aggregate of equal size: the scalar is stored into a slot, or the scalar is loaded from the aggregate's address.
@(private)
lower_transmute_across_classes :: proc(state: ^Procedure_State, source_id, target_id: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	if scalar_type(state, source_id) == .None { return lower_load(state, value, target_id) }
	target_layout := state.job.layouts[target_id]
	slot := ir.stack_slot(state.job.function, state.entry_control, u32(target_layout.size), u32(target_layout.align))
	lower_store(state, slot, value, source_id)
	return slot
}

// Copies an aggregate operand (its address) into a fresh slot of the target type, for casts such as []u8 <-> string.
@(private)
lower_same_layout_conversion :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Conversion_Plan,
	source_id: types.Type_Id,
	address: ir.Node_Id,
) -> ir.Node_Id {
	source_layout := state.job.layouts[source_id]
	target_layout := state.job.layouts[plan.target]
	if source_layout.error != .None || target_layout.error != .None || source_layout.size != target_layout.size || scalar_type(state, source_id) != .None {
		return lower_fail(state, node, .Conversion)
	}
	copy := ir.stack_slot(state.job.function, state.entry_control, u32(target_layout.size), u32(target_layout.align))
	lower_store(state, copy, address, plan.target)
	return copy
}
