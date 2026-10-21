package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Splats `value` into a fresh slot of the array type `target`. An element equal to `source` takes the value
// itself, so a scalar fills the innermost element of nested arrays and an aggregate is copied into every element.
@(private)
lower_broadcast_array :: proc(state: ^Procedure_State, node: syntax.Node_Index, target, source: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	layout := state.job.layouts[target]
	if layout.error != .None { return lower_fail(state, node, .Conversion) }
	function := state.job.function
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	lower_broadcast_elements(state, node, slot, target, source, value)
	if state.failed || function.error != nil { return 0 }
	return slot
}

@(private)
lower_broadcast_elements :: proc(state: ^Procedure_State, node: syntax.Node_Index, address: ir.Node_Id, array_type, source: types.Type_Id, value: ir.Node_Id) {
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, array_type))
	element_layout := state.job.layouts[descriptor.elem]
	if element_layout.error != .None {
		_ = lower_fail(state, node, .Conversion)
		return
	}
	element_is_array := types.get(store, types.resolve_named(store, descriptor.elem)).kind == .Array
	function := state.job.function
	for index in 0 ..< descriptor.count {
		element := ir.ptr_offset(function, address, i64(index) * i64(element_layout.size))
		if descriptor.elem == source {
			lower_store(state, element, value, descriptor.elem)
		} else if element_is_array {
			lower_broadcast_elements(state, node, element, descriptor.elem, source, value)
		} else {
			_ = lower_fail(state, node, .Conversion)
			return
		}
		if state.failed || function.error != nil { return }
	}
}

// The scalar that an untyped source converts to before it splats: the innermost element of nested arrays.
@(private)
broadcast_leaf_type :: proc(state: ^Procedure_State, array_type: types.Type_Id) -> types.Type_Id {
	store := check.type_store(state.job.program)
	leaf := array_type
	for {
		descriptor := types.get(store, types.resolve_named(store, leaf))
		if descriptor.kind != .Array { return leaf }
		leaf = descriptor.elem
	}
}
