package lower

import "core:fmt"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A literal lives in frame or, in startup code, static storage; the value is that storage's address, as for every aggregate.
@(private)
lower_aggregate :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Aggregate_Plan) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	store := check.type_store(state.job.program)
	owner := types.resolve_named(store, plan.type)
	if types.get(store, owner).kind == .Bit_Field { return lower_bit_field_aggregate(state, node, plan, owner) }
	layout := state.job.layouts[plan.type]
	if layout.error != .None || layout.size > i64(max(u32)) || len(plan.field_indices) != len(plan.values) { return lower_fail(state, node, .Expression) }
	return lower_aggregate_into(state, node, plan, aggregate_storage(state, layout), layout.size)
}

// A literal lives in its frame slot, which dies with the call. Startup code runs once, so an aggregate whose address
// outlives it (a literal under `&` stored into a global) needs static storage instead, the way slice backing already
// materializes a hidden global. Generated startup procedures have no procedure entity, while every real procedure has
// one; the module alone cannot tell them apart, since it is present in every procedure body.
@(private)
aggregate_storage :: proc(state: ^Procedure_State, layout: Type_Layout) -> ir.Node_Id {
	function := state.job.function
	module := state.job.module
	if module == nil || state.job.procedure.entity != 0 {
		return ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	}
	index := len(module.globals)
	name := fmt.aprintf("__odinc_internal_aggregate_%d", index, allocator = virtual.arena_allocator(&module.arena))
	if _, error := append(&module.globals, ir.Global{name = name, size = u32(max(layout.size, 1)), align = u32(layout.align), mutable = true}); error != nil {
		state.job.allocation_error = error
		state.failed = true
		return 0
	}
	return ir.symbol_addr(function, ir.Symbol_Ref{space = .Global, index = u32(index)})
}

// Fills the size bytes at address with the plan's values, zeroing the rest first.
@(private)
lower_aggregate_into :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Aggregate_Plan, address: ir.Node_Id, size: i64) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	store := check.type_store(state.job.program)
	owner := types.resolve_named(store, plan.type)
	if types.get(store, owner).kind == .Struct && types.get(store, owner).soa == .Fixed {
		return lower_soa_fixed_literal(state, node, plan, address, size)
	}
	return lower_aggregate_struct_into(state, node, plan, address, size)
}

// The column-wise fill for plain struct, array and matrix aggregates, and for
// constant fixed `#soa` aggregates whose checker constant is already
// transposed into spread columns. Row-wise fixed `#soa` plans keep their own
// scatter in lower_soa_fixed_literal and never reach here.
@(private)
lower_aggregate_struct_into :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Aggregate_Plan,
	address: ir.Node_Id,
	size: i64,
) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	store := check.type_store(state.job.program)
	owner := types.resolve_named(store, plan.type)
	function := state.job.function
	lower_zero_memory(state, address, size)
	for value, position in plan.values {
		index := int(plan.field_indices[position])
		descriptor := types.get(store, owner)
		field_type := descriptor.elem
		offset: i64
		if descriptor.kind == .Array || descriptor.kind == .Enumerated_Array || descriptor.kind == .Simd_Vector || descriptor.kind == .Matrix {
			element_layout := state.job.layouts[field_type]
			if element_layout.error != .None { return lower_fail(state, node, .Expression) }
			offset = i64(index) * element_layout.size
		} else {
			found: bool
			field_type, found = types.field_type(store, owner, index)
			if !found { return lower_fail(state, node, .Expression) }
			field_offset, offset_error := types.field_offset(store, owner, index)
			if offset_error != .None { return lower_fail(state, node, .Expression) }
			offset = field_offset
		}
		if position < len(plan.field_paths) && len(plan.field_paths[position]) > 1 {
			for step in plan.field_paths[position][1:] {
				field_offset, offset_error := types.field_offset(store, step.type, int(step.field_index))
				if offset_error != .None || step.indirect { return lower_fail(state, node, .Expression) }
				field_type = types.get(store, step.type).fields[step.field_index].type
				offset += field_offset
			}
		}
		field_value: ir.Node_Id
		if position < len(plan.conversions) && plan.conversions[position] != 0 {
			field_value = lower_declared_conversion(state, node, plan.conversions[position])
		} else {
			field_value = lower_operand(state, value, field_type)
		}
		if state.failed { return 0 }
		lower_store(state, ir.ptr_offset(function, address, offset), field_value, field_type)
		if state.failed { return 0 }
	}
	return address
}
