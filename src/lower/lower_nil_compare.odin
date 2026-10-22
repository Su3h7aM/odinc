package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

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
	is_nil := lower_value_is_nil(state, lower_info(state, node).type, value)
	if expression.op.kind == .Not_Eq { return ir.binary(function, .Xor, is_nil, ir.const_int(function, .Bool, 1)) }
	return is_nil
}

@(private)
lower_value_is_nil :: proc(state: ^Procedure_State, type: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	descriptor := lower_type(state, type)
	if descriptor.kind == .Union {
		resolved := types.resolve_named(check.type_store(state.job.program), type)
		return lower_union_nil_comparison(state, resolved, .Cmp_Eq, value)
	}
	if scalar_type(state, type) != .None {
		return ir.compare(function, .Eq, value, ir.const_int(function, function.nodes.type[value], 0))
	}
	data := lower_load_word(state, value, .Ptr)
	if descriptor.kind != .Any {
		return ir.compare(function, .Eq, data, ir.const_int(function, .Ptr, 0))
	}
	typeid_word := lower_load_word(state, ir.ptr_offset(function, value, 8), .I64)
	data_is_nil := ir.compare(function, .Eq, data, ir.const_int(function, .Ptr, 0))
	typeid_is_nil := ir.compare(function, .Eq, typeid_word, ir.const_int(function, .I64, 0))
	return ir.binary(function, .Or, data_is_nil, typeid_is_nil)
}
