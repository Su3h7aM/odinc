package lower

import "oc:ir"
import "oc:syntax"

// Mirrors lb_emit_comp_against_nil: a slice, dynamic array or map is nil when its data word is zero; an any is nil
// when its data word or its typeid word is zero. The nil literal is the other operand of == or !=.
@(private)
is_nil_comparison :: proc(state: ^Procedure_State, expression: syntax.Binary_Expr) -> bool {
	if expression.op.kind != .Cmp_Eq && expression.op.kind != .Not_Eq { return false }
	if !lower_nil_operand(state, expression.left) && !lower_nil_operand(state, expression.right) { return false }
	return nil_comparable_kind(state, expression.left) || nil_comparable_kind(state, expression.right)
}

@(private)
nil_comparable_kind :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> bool {
	#partial switch lower_type(state, lower_info(state, node).type).kind {
	case .Slice, .Dynamic_Array, .Map, .Any:
		return true
	}
	return false
}

@(private)
lower_nil_comparison :: proc(state: ^Procedure_State, expression: syntax.Binary_Expr, left, right: ir.Node_Id) -> ir.Node_Id {
	value, node := left, expression.left
	if lower_nil_operand(state, expression.left) { value, node = right, expression.right }
	function := state.job.function
	data := lower_load_word(state, value, .Ptr)
	if lower_type(state, lower_info(state, node).type).kind != .Any {
		kind := ir.Node_Kind.Eq if expression.op.kind == .Cmp_Eq else ir.Node_Kind.Ne
		return ir.compare(function, kind, data, ir.const_int(function, .Ptr, 0))
	}
	typeid_word := lower_load_word(state, ir.ptr_offset(function, value, 8), .I64)
	data_is_nil := ir.compare(function, .Eq, data, ir.const_int(function, .Ptr, 0))
	typeid_is_nil := ir.compare(function, .Eq, typeid_word, ir.const_int(function, .I64, 0))
	if expression.op.kind == .Cmp_Eq { return ir.binary(function, .Or, data_is_nil, typeid_is_nil) }
	data_is_set := ir.compare(function, .Ne, data, ir.const_int(function, .Ptr, 0))
	typeid_is_set := ir.compare(function, .Ne, typeid_word, ir.const_int(function, .I64, 0))
	return ir.binary(function, .And, data_is_set, typeid_is_set)
}
