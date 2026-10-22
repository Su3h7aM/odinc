package check

import "oc:syntax"
import "oc:types"

@(private = "package")
expression_argument_needs_hint :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	unwrapped := type_unparen(file, node)
	#partial switch file.ast.nodes[unwrapped].kind {
	case .Implicit_Selector_Expr, .Comp_Lit, .Ternary_When_Expr, .Ternary_If_Expr, .Auto_Cast:
		return true
	case .Unary_Expr:
		unary := syntax.node_payload(file.ast, unwrapped, syntax.Unary_Expr)
		return unary.op.kind == .And && file.ast.nodes[type_unparen(file, unary.expr)].kind == .Comp_Lit
	}
	return false
}

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
	if expression_argument_needs_hint(file, node) { return check_expression(checker, view, scope, node, target) }
	#partial switch file.ast.nodes[node].kind {
	case .Call_Expr:
		if is_type_of_call(file, node) { break }
		if definition := record_call_definition(checker.type_checker, checker.views[view].file, file, scope, node) or_return; definition != 0 { break }
		callee := check_expression(checker, view, scope, syntax.node_payload(file.ast, node, syntax.Call_Expr).expr) or_return
		if callee.mode == .Builtin && length_integer_hint(checker, target) != 0 {
			builtin := entity_get(checker.type_checker.resolver.scopes, callee.entity).data.(Builtin_Id)
			kind := checker.builtin_kinds[builtin]
			if kind == .Len || kind == .Cap { return check_expression(checker, view, scope, node, target) }
		}
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
		store := checker.type_checker.store
		if info.mode == .Constant && types.is_untyped(store, info.type) && types.get(store, types.resolve_named(store, target)).kind == .Array {
			return expression_conversion(checker, view, scope, node, Operand(info.constant), info, target, .Assignment)
		}
		return check_expression(checker, view, scope, node, target)
	}
	if info.mode == .Type { return expression_type_argument_failure(checker, view, scope, node, target, info.type) }
	if expression_is_typeid(checker, target) { return expression_value_argument_failure(checker, view, scope, node, target, info.type) }
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
