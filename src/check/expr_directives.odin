package check

import "oc:syntax"
import "oc:types"

@(private = "package")
expression_is_auto_cast :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	return file.ast.nodes[type_unparen(file, node)].kind == .Auto_Cast
}

@(private = "package")
expression_auto_cast_comparison :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	binary: syntax.Binary_Expr,
	left, right: Expression_Info,
) -> (
	converted_left, converted_right: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	source, operand, target := binary.left, left, right.type
	if !expression_is_auto_cast(file, source) { source, operand, target = binary.right, right, left.type }
	_, diagnostic, failure := check_conversion(
		checker.constants,
		checker.type_checker.store,
		expression_value_operand(checker, view, source, operand),
		operand,
		target,
		.Cast,
		checker.config,
	)
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), expression_poison(scope), nil
	}
	if diagnostic != .None {
		poison, report_error := expression_failure(checker, view, scope, node, .Mismatched_Types)
		return poison, poison, report_error
	}
	if left.mode == .Constant && right.mode == .Constant { return left, right, nil }
	target = left.type
	if left.mode == .Constant {
		target = right.type
	} else if right.mode != .Constant {
		left_size, _, left_error := types.layout(checker.type_checker.store, left.type)
		right_size, _, right_error := types.layout(checker.type_checker.store, right.type)
		if left_error != .None || right_error != .None {
			poison, report_error := expression_unsupported(checker, view, scope, node, "Auto_Cast_Comparison_Layout")
			return poison, poison, report_error
		}
		if left_size < right_size { target = right.type }
	}
	converted_left, converted_right = left, right
	if left.type != target {
		converted_left = expression_conversion(
			checker,
			view,
			scope,
			binary.left,
			expression_value_operand(checker, view, binary.left, left),
			left,
			target,
			.Cast,
		) or_return
	}
	if right.type != target {
		converted_right = expression_conversion(
			checker,
			view,
			scope,
			binary.right,
			expression_value_operand(checker, view, binary.right, right),
			right,
			target,
			.Cast,
		) or_return
	}
	return
}

@(private)
expression_auto_cast :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	conversion := syntax.node_payload(file.ast, node, syntax.Auto_Cast)
	operand_hint := types.Type_Id(0)
	if expression_needs_operand_hint(file, conversion.expr) || expression_is_auto_cast(file, conversion.expr) { operand_hint = hint }
	operand := check_expression(checker, view, scope, conversion.expr, operand_hint) or_return
	target := hint if hint != 0 else operand.type
	return expression_conversion(
		checker,
		view,
		scope,
		node,
		expression_value_operand(checker, view, conversion.expr, operand),
		expression_single_value(operand),
		target,
		.Cast,
	)
}

@(private)
expression_procedure_directive :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	name := expression_text(file, node)
	switch name {
	case "#file", "#line", "#directory", "#location":
		return expression_source_directive(checker, view, scope, node, name, nil)
	case "#procedure":
	case:
		return expression_unsupported(checker, view, scope, node, "Expression_Kind")
	}
	scopes := checker.type_checker.resolver.scopes
	for current := scope; current != 0; current = scope_get(scopes, current).parent {
		binding := scope_get(scopes, current)
		if binding.kind != .Procedure { continue }
		procedure := entity_get(scopes, binding.owner).data.(Procedure_Data)
		if procedure.definition != 0 { procedure = entity_get(scopes, procedure.definition).data.(Procedure_Data) }
		constant, failure := constant_pool_intern_string(checker.constants, procedure.source_name, types.TYPE_UNTYPED_STRING)
		if failure != nil {
			expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = types.TYPE_UNTYPED_STRING, mode = .Constant, constant = constant, scope = scope, state = .Checked}, nil
	}
	return expression_unsupported(checker, view, scope, node, "Procedure_Directive_Scope")
}
