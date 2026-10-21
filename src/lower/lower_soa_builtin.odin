package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// soa_zip stores the data pointers of its slice operands into a fresh #soa
// slice header, as the official lb_soa_zip does (llvm_backend_utility.cpp).
// The fields alias the inputs; the length is the minimum input length.
@(private)
lower_soa_zip :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	if info.type == 0 || len(plan.arguments) == 0 { return lower_fail(state, node, .Builtin) }
	soa := types.resolve_named(store, info.type)
	descriptor := types.get(store, soa)
	if descriptor.kind != .Struct || descriptor.soa != .Slice { return lower_fail(state, node, .Builtin) }
	_, _, spread := lower_soa_store_types(store, soa)
	if spread != len(plan.arguments) { return lower_fail(state, node, .Builtin) }
	for argument in plan.arguments {
		if !call_operand_valid(state, argument) { return lower_fail(state, node, .Builtin) }
		if lower_type(state, operand_type(state, argument)).kind != .Slice { return lower_fail(state, node, .Builtin) }
	}
	layout := state.job.layouts[info.type]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	bases := make([]ir.Node_Id, len(plan.arguments), context.temp_allocator)
	length: ir.Node_Id
	for argument, index in plan.arguments {
		header := lower_operand(state, argument)
		if state.failed || function.error != nil { return 0 }
		base, count := lower_header_parts(state, header)
		if state.failed || function.error != nil { return 0 }
		bases[index] = base
		length = count if index == 0 else pick_ordered(function, .SLt, length, count, true)
	}
	for base, index in bases {
		offset, offset_error := types.field_offset(store, soa, index)
		if offset_error != .None { return lower_fail(state, node, .Builtin) }
		lower_store_word(state, ir.ptr_offset(function, slot, offset), base)
	}
	length_offset, length_error := types.field_offset(store, soa, spread)
	if length_error != .None { return lower_fail(state, node, .Builtin) }
	lower_store_word(state, ir.ptr_offset(function, slot, length_offset), length)
	return slot
}

// soa_unzip rebuilds one slice header per field over the #soa slice's data,
// as the official lb_soa_unzip does (llvm_backend_utility.cpp).
@(private)
lower_soa_unzip :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan, results: []ir.Node_Id) {
	function := state.job.function
	store := check.type_store(state.job.program)
	if len(plan.arguments) != 1 || len(plan.results) == 0 || len(plan.results) > len(results) {
		lower_fail(state, node, .Builtin)
		return
	}
	if !call_operand_valid(state, plan.arguments[0]) { lower_fail(state, node, .Builtin); return }
	soa := types.resolve_named(store, operand_type(state, plan.arguments[0]))
	descriptor := types.get(store, soa)
	if descriptor.kind != .Struct || descriptor.soa != .Slice { lower_fail(state, node, .Builtin); return }
	_, _, spread := lower_soa_store_types(store, soa)
	if spread != len(plan.results) { lower_fail(state, node, .Builtin); return }
	address := lower_operand(state, plan.arguments[0])
	if state.failed || function.error != nil { return }
	length := lower_soa_length(state, node, soa, address)
	if state.failed || function.error != nil { return }
	for result, index in plan.results {
		if lower_type(state, result).kind != .Slice { lower_fail(state, node, .Builtin); return }
		offset, offset_error := types.field_offset(store, soa, index)
		if offset_error != .None { lower_fail(state, node, .Builtin); return }
		field := lower_load_word(state, ir.ptr_offset(function, address, offset), .Ptr)
		if state.failed || function.error != nil { return }
		slot := ir.stack_slot(function, state.entry_control, 16, 8)
		lower_store_word(state, slot, field)
		lower_store_word(state, ir.ptr_offset(function, slot, 8), length)
		results[index] = slot
	}
}
