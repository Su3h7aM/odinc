package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

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
	for element, index in argument.variadic_elements {
		if !call_operand_valid(state, element) { return lower_fail(state, node, .Call_Argument) }
		value := lower_operand(state, element, element_type)
		if state.failed || function.error != nil { return 0 }
		lower_store(state, ir.ptr_offset(function, storage, i64(index) * element_layout.size), value, element_type)
	}
	lower_store_word(state, header, storage)
	lower_store_word(state, ir.ptr_offset(function, header, 8), ir.const_int(function, .I64, i64(count)))
	return header
}
