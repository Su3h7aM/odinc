package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// lower_variadic_spread passes the slice of a `..` argument as the variadic parameter's value.
@(private)
lower_variadic_spread :: proc(state: ^Procedure_State, node: syntax.Node_Index, argument: check.Call_Argument, slice_type: types.Type_Id) -> ir.Node_Id {
	if lower_type(state, slice_type).kind != .Slice { return lower_fail(state, node, .Call_Argument) }
	if argument.conversion != 0 {
		plan, ok := check.plan(state.job.program, argument.conversion)^.(check.Conversion_Plan)
		if !ok { return lower_fail(state, node, .Conversion) }
		return lower_conversion(state, plan, node)
	}
	if !call_operand_valid(state, argument.value) { return lower_fail(state, node, .Call_Argument) }
	return lower_operand(state, argument.value, slice_type)
}

// lower_variadic_slice stores the packed elements of a variadic argument in a stack array and returns the slice header.
@(private)
lower_variadic_slice :: proc(state: ^Procedure_State, node: syntax.Node_Index, argument: check.Call_Argument, slice_type: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	element_type := lower_type(state, slice_type).elem
	element_layout := state.job.layouts[element_type]
	if element_layout.error != .None { return lower_fail(state, node, .Call_Argument) }
	count := len(argument.variadic_elements)
	header := ir.stack_slot(function, state.entry_control, 16, 8)
	if count == 0 {
		lower_store_word(state, header, ir.const_int(function, .Ptr, 0))
		lower_store_word(state, ir.ptr_offset(function, header, 8), ir.const_int(function, .I64, 0))
		return header
	}
	storage := ir.stack_slot(function, state.entry_control, u32(element_layout.size) * u32(count), u32(element_layout.align))
	spread_node: syntax.Node_Index
	spread_values: []ir.Node_Id
	for element, index in argument.variadic_elements {
		value: ir.Node_Id
		if argument.variadic_tuple_elements[index] != 0 {
			ref, is_ref := element.(check.Expression_Ref)
			if !is_ref || ref.view != state.view { return lower_fail(state, node, .Call_Argument) }
			if spread_values == nil || spread_node != ref.node {
				spread_values = lower_spread_results(state, node, ref)
				spread_node = ref.node
				if state.failed || function.error != nil { return 0 }
			}
			element_index := argument.variadic_tuple_elements[index] - 1
			if element_index >= len(spread_values) { return lower_fail(state, node, .Call_Argument) }
			value = spread_values[element_index]
		} else if argument.variadic_conversions[index] != 0 {
			value = lower_conversion(state, check.plan(state.job.program, argument.variadic_conversions[index])^.(check.Conversion_Plan), node)
		} else {
			if !call_operand_valid(state, element) { return lower_fail(state, node, .Call_Argument) }
			value = lower_operand(state, element, element_type)
		}
		if state.failed || function.error != nil { return 0 }
		lower_store(state, ir.ptr_offset(function, storage, i64(index) * element_layout.size), value, element_type)
	}
	lower_store_word(state, header, storage)
	lower_store_word(state, ir.ptr_offset(function, header, 8), ir.const_int(function, .I64, i64(count)))
	return header
}
