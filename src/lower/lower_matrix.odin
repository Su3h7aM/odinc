package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// A matrix element lives at its storage index: column-major storage holds columns, row-major storage holds rows.
// Constant indices are checked by the checker, so the address needs no runtime bounds check.
@(private)
lower_matrix_index_address :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Matrix_Index_Plan) -> ir.Node_Id {
	base, is_expression := plan.base.(check.Expression_Ref)
	if !is_expression || base.view != state.view { return lower_fail(state, node, .Place) }
	shape := lower_type(state, lower_info(state, base.node).type)
	if shape.kind != .Matrix { return lower_fail(state, node, .Place) }
	element := state.job.layouts[shape.elem]
	if element.error != .None { return lower_fail(state, node, .Place) }
	storage: i64
	if shape.row_major {
		storage = plan.row * shape.upper_bound + plan.column
	} else {
		storage = plan.column * shape.count + plan.row
	}
	address := lower_array_base(state, base.node)
	if state.failed || state.job.function.error != nil { return 0 }
	return ir.ptr_offset(state.job.function, address, storage * element.size)
}
