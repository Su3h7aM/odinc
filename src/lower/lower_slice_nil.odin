package lower

import "oc:ir"
import "oc:syntax"

// A slice is nil when its data pointer is zero, as official lb_emit_comp_against_nil compares it. Slices have no
// other equality, so one operand of == or != is the nil literal.
@(private)
is_slice_nil_comparison :: proc(state: ^Procedure_State, expression: syntax.Binary_Expr) -> bool {
	if expression.op.kind != .Cmp_Eq && expression.op.kind != .Not_Eq { return false }
	return(
		lower_type(state, lower_info(state, expression.left).type).kind == .Slice ||
		lower_type(state, lower_info(state, expression.right).type).kind == .Slice \
	)
}

@(private)
lower_slice_nil_comparison :: proc(state: ^Procedure_State, expression: syntax.Binary_Expr, left, right: ir.Node_Id) -> ir.Node_Id {
	slice := left
	if lower_type(state, lower_info(state, expression.left).type).kind != .Slice { slice = right }
	function := state.job.function
	data := lower_load_word(state, slice, .Ptr)
	kind := ir.Node_Kind.Eq if expression.op.kind == .Cmp_Eq else ir.Node_Kind.Ne
	return ir.compare(function, kind, data, ir.const_int(function, .Ptr, 0))
}
