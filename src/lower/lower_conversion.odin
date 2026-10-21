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
	if plan.kind == .Union_Injection && plan.source_type != 0 { source_id = plan.source_type }
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
	if plan.kind == .Union_Injection { return lower_union_injection(state, node, plan, source_id, value) }
	if len(plan.path) != 0 {
		store := check.type_store(state.job.program)
		field_type := source_id
		for step, index in plan.path {
			if index != 0 && step.indirect { value = lower_load(state, value, field_type) }
			owner := types.get(store, types.resolve_named(store, step.type))
			if owner.kind != .Struct || int(step.field_index) >= len(owner.fields) { return lower_fail(state, node, .Conversion) }
			offset, offset_error := types.field_offset(store, step.type, int(step.field_index))
			if offset_error != .None { return lower_fail(state, node, .Conversion) }
			value = ir.ptr_offset(state.job.function, value, i64(offset))
			field_type = owner.fields[step.field_index].type
		}
		target := types.get(store, types.resolve_named(store, plan.target))
		if target.kind == .Pointer && field_type == target.elem { return value }
		return lower_load(state, value, plan.target)
	}
	store := check.type_store(state.job.program)
	source_kind := types.get(store, types.resolve_named(store, source_id)).kind
	target_kind := types.get(store, types.resolve_named(store, plan.target)).kind
	if source_kind == .CString && target_kind == .String {
		return lower_cstring_to_string(state, node, value, 1, .I8, plan.target)
	}
	if source_kind == .CString16 && target_kind == .String16 {
		return lower_cstring_to_string(state, node, value, 2, .I16, plan.target)
	}
	if scalar_type(state, source_id) != .None && lower_type(state, plan.target).kind == .Simd_Vector {
		return lower_simd_broadcast(state, plan.target, value)
	}
	if (scalar_type(state, source_id) != .None || lower_complex_kind(state, source_id)) && lower_type(state, plan.target).kind == .Matrix {
		return lower_matrix_scalar_init(state, node, plan.target, value)
	}
	if lower_type(state, source_id).kind == .Matrix && lower_type(state, plan.target).kind == .Matrix {
		return lower_matrix_cast(state, node, source_id, plan.target, value)
	}
	if lower_complex_kind(state, source_id) && lower_complex_kind(state, plan.target) {
		return lower_complex_conversion(state, node, value, source_id, plan.target)
	}
	function := state.job.function
	if scalar_type(state, plan.target) == .Bool {
		if is_wide_integer(state, source_id) {
			words := wide_load(state, value)
			zero := ir.const_int(function, .I64, 0)
			return ir.binary(function, .Or, ir.compare(function, .Ne, words.low, zero), ir.compare(function, .Ne, words.high, zero))
		}
		value_type := function.nodes.type[value]
		if value_type == .Bool { return value }
		if value_type >= .I8 && value_type <= .I64 {
			return ir.compare(function, .Ne, value, ir.const_int(function, value_type, 0))
		}
		return lower_fail(state, node, .Conversion)
	}
	if is_wide_integer(state, plan.target) || is_wide_integer(state, source_id) {
		return lower_wide_conversion(state, node, source_id, plan.target, value)
	}
	if plan.kind == .Transmute && (scalar_type(state, source_id) == .None) != (scalar_type(state, plan.target) == .None) {
		return lower_transmute_across_classes(state, source_id, plan.target, value)
	}
	if source_kind == .Untyped_Nil { return value }
	if scalar_type(state, plan.target) == .None { return lower_same_layout_conversion(state, node, plan, source_id, value) }
	source := function.nodes.type[value]
	target := scalar_type(state, plan.target)
	if source == target { return value }
	if target == .None { return lower_fail(state, node, .Conversion) }
	if plan.kind == .Transmute {
		return ir.convert(function, .Bitcast, value, target)
	}
	if source == .Bool && target >= .I8 && target <= .I64 {
		value = ir.convert(function, .Zext, value, .I8)
		source = .I8
	}
	source_signed := signed_type(state, source_id)
	if source == .Ptr || target == .Ptr {
		if source != .I64 && source != .Ptr || target != .I64 && target != .Ptr { return lower_fail(state, node, .Conversion) }
		return ir.convert(function, .Bitcast, value, target)
	}
	source_bits := scalar_bits(source)
	target_bits := scalar_bits(target)
	if plan.kind != .Transmute && is_float16(state, source_id) {
		value = float16_widen(function, value)
		source = .F32
	}
	if plan.kind != .Transmute && is_float16(state, plan.target) {
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
			if source == target { return value }
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

// `value` as a union variant: the payload at offset 0, then the tag word (none for maybe-pointer unions).
@(private)
lower_union_injection :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Conversion_Plan,
	source_id: types.Type_Id,
	value: ir.Node_Id,
) -> ir.Node_Id {
	store := check.type_store(state.job.program)
	union_id := types.resolve_named(store, plan.target)
	layout, layout_error := types.union_layout(store, union_id)
	if layout_error != .None { return lower_fail(state, node, .Conversion) }
	descriptor := types.get(store, union_id)
	function := state.job.function
	union_slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.alignment))
	lower_store(state, union_slot, value, source_id)
	if state.failed || state.job.function.error != nil { return 0 }
	if descriptor.union_form == .Maybe_Pointer { return union_slot }
	for variant, index in descriptor.variants {
		if !types.are_identical(store, variant, source_id) { continue }
		tag := i64(index)
		if descriptor.union_form != .No_Nil { tag += 1 }
		tag_address := ir.ptr_offset(function, union_slot, layout.variant_block_size)
		lower_store_word(state, tag_address, ir.const_int(function, tag_value_type(layout.tag_size), tag))
		return union_slot
	}
	return lower_fail(state, node, .Conversion)
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
