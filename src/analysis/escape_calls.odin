package analysis

import "oc:check"
import "oc:syntax"

@(private = "package")
escape_retain_known_effects :: proc(escape: ^Escape, operand: check.Operand) -> bool {
	expression: check.Expression_Ref
	switch value in operand {
	case check.Expression_Ref:
		expression = value
	case check.Projection:
		expression = value.expression
	case check.Entity_Id, check.Const_Id:
		return true
	}
	if !escape_has_unknown_effects(escape, expression) { return true }
	for &value in escape.memory { value = 0 }
	escape.live_facts = 0
	escape.reachable = false
	return false
}

@(private = "file")
escape_has_unknown_effects :: proc(escape: ^Escape, expression: check.Expression_Ref) -> bool {
	if expression.node == 0 { return false }
	program := escape.run.program
	ast := program.files[program.typed_views[expression.view].file].ast
	info := check.expression_info(program, expression.view, expression.node)
	if info.entity != 0 && .Field in program.entities[info.entity].flags && info.plan == 0 { return true }
	if info.plan != 0 {
		#partial switch _ in check.plan(program, info.plan)^ {
		case check.Soa_Plan, check.Swizzle_Plan:
			return true
		}
	}
	#partial switch payload in ast.nodes[expression.node].payload {
	case syntax.Call_Expr:
		for argument in syntax.node_list(ast, payload.args) { if escape_has_unknown_effects(escape, {expression.view, argument}) { return true } }
	case syntax.Selector_Call_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.call})
	case syntax.Paren_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr})
	case syntax.Unary_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr})
	case syntax.Deref_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr})
	case syntax.Selector_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr})
	case syntax.Auto_Cast:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr})
	case syntax.Type_Cast:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr})
	case syntax.Tag_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr})
	case syntax.Or_Return_Expr:
		return false
	case syntax.Or_Branch_Expr:
		return false
	case syntax.Type_Assertion:
		return true
	case syntax.Field_Value:
		return escape_has_unknown_effects(escape, {expression.view, payload.value})
	case syntax.Binary_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.left}) || escape_has_unknown_effects(escape, {expression.view, payload.right})
	case syntax.Ternary_Expr:
		return(
			escape_has_unknown_effects(escape, {expression.view, payload.x}) ||
			escape_has_unknown_effects(escape, {expression.view, payload.cond}) ||
			escape_has_unknown_effects(escape, {expression.view, payload.y}) \
		)
	case syntax.Or_Else_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.x}) || escape_has_unknown_effects(escape, {expression.view, payload.y})
	case syntax.Index_Expr:
		return escape_has_unknown_effects(escape, {expression.view, payload.expr}) || escape_has_unknown_effects(escape, {expression.view, payload.index})
	case syntax.Slice_Expr:
		return(
			escape_has_unknown_effects(escape, {expression.view, payload.expr}) ||
			escape_has_unknown_effects(escape, {expression.view, payload.low}) ||
			escape_has_unknown_effects(escape, {expression.view, payload.high}) \
		)
	case syntax.Matrix_Index_Expr:
		return(
			escape_has_unknown_effects(escape, {expression.view, payload.expr}) ||
			escape_has_unknown_effects(escape, {expression.view, payload.row_index}) ||
			escape_has_unknown_effects(escape, {expression.view, payload.column_index}) \
		)
	case syntax.Comp_Lit:
		for element in syntax.node_list(ast, payload.elems) { if escape_has_unknown_effects(escape, {expression.view, element}) { return true } }
	}
	return false
}
