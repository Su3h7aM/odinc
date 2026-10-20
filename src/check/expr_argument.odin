package check

import "oc:syntax"
import "oc:types"

// A runtime argument converts to its parameter type through its own conversion plan, which the call retains; the
// argument keeps its unconverted type. Constants and expressions that need the parameter type to be checked take it as a hint.
// An `#any_int` parameter also accepts a typed integer or enum argument by cast, as official check_expr.cpp:7487-7493.
@(private = "package")
expression_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	target: types.Type_Id,
	any_integer: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	#partial switch file.ast.nodes[node].kind {
	case .Implicit_Selector_Expr, .Comp_Lit, .Ternary_When_Expr, .Ternary_If_Expr:
		return check_expression(checker, view, scope, node, target)
	}
	info = check_expression(checker, view, scope, node) or_return
	info = expression_single_value(info)
	if info.state == .Invalid || info.type == target { return info, nil }
	if any_integer && expression_any_integer_source(checker, info, target) {
		source := Operand(Expression_Ref{view, node})
		if info.mode == .Constant { source = Operand(info.constant) }
		return expression_conversion(checker, view, scope, node, source, info, target, .Cast)
	}
	if info.mode == .Constant || (info.mode == .Type && expression_is_typeid(checker, target)) {
		return check_expression(checker, view, scope, node, target)
	}
	return expression_conversion(checker, view, scope, node, Operand(Expression_Ref{view, node}), info, target, .Assignment)
}

// An optional-ok or map-index operand used as one value is a value; the mode only marks the comma-ok form.
@(private = "package")
expression_single_value :: proc(info: Expression_Info) -> Expression_Info {
	result := info
	#partial switch info.mode {
	case .Map_Index, .Optional_Ok, .Optional_Ok_Pointer:
		result.mode = .Value
	}
	return result
}

@(private = "file")
expression_is_typeid :: proc(checker: ^Expression_Checker, target: types.Type_Id) -> bool {
	return target != types.TYPE_NONE && types.get(checker.type_checker.store, target).kind == .Type_Id
}

@(private = "package")
expression_any_integer_source :: proc(checker: ^Expression_Checker, info: Expression_Info, target: types.Type_Id) -> bool {
	store := checker.type_checker.store
	if info.mode == .Type || types.is_untyped(store, info.type) { return false }
	source_kind := types.get(store, types.resolve_named(store, info.type)).kind
	target_kind := types.get(store, types.resolve_named(store, target)).kind
	return target_kind == .Integer && (source_kind == .Integer || source_kind == .Enum)
}
