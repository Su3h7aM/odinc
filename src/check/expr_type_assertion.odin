package check

import "oc:syntax"
import "oc:types"

@(private = "package")
expression_type_assertion :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	assertion := syntax.node_payload(file.ast, node, syntax.Type_Assertion)
	source := check_expression(checker, view, scope, assertion.expr) or_return
	if source.state == .Invalid { return expression_poison(scope), nil }
	if source.mode == .Constant || types.is_untyped(checker.type_checker.store, source.type) {
		return expression_failure(checker, view, scope, assertion.expr, .Invalid_Operand)
	}
	store := checker.type_checker.store
	source_base := types.resolve_named(store, source.type)
	source_descriptor := types.get(store, source_base)
	pointer_source := source_descriptor.kind == .Pointer
	if pointer_source {
		source_base = types.resolve_named(store, source_descriptor.elem)
		source_descriptor = types.get(store, source_base)
	}
	if source_descriptor.kind != .Union && source_descriptor.kind != .Any {
		return expression_unsupported(checker, view, scope, node, "Type_Assertion_Source")
	}
	question := false
	target := types.Type_Id(0)
	variant := -1
	if assertion.type != 0 {
		if file.ast.nodes[assertion.type].kind == .Unary_Expr {
			unary := syntax.node_payload(file.ast, assertion.type, syntax.Unary_Expr)
			question = unary.op.kind == .Question
		}
		if question {
			if source_descriptor.kind != .Union { return expression_unsupported(checker, view, scope, node, "Type_Assertion_Question") }
			if len(source_descriptor.variants) == 1 {
				target = source_descriptor.variants[0]
			} else if hint != 0 {
				target = hint
			}
		} else {
			target = type_expression(checker.type_checker, file_id, scope, assertion.type, true) or_return
		}
	} else if hint != 0 {
		target = hint
	}
	if target == 0 { return expression_unsupported(checker, view, scope, node, "Type_Assertion_Target") }
	if source_descriptor.kind == .Union {
		for item, index in source_descriptor.variants {
			if item == target { variant = index; break }
		}
		if variant < 0 { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
	}
	expression_record_type_info(checker, source.type) or_return
	expression_record_type_info(checker, target) or_return
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(
			Type_Assertion_Plan {
				source = Operand(Expression_Ref{view, assertion.expr}),
				source_type = source.type,
				target_type = target,
				variant = variant,
				comma_ok = false,
			},
		),
	) or_return
	return Expression_Info{type = target, mode = .Optional_Ok, plan = plan, scope = scope, state = .Checked}, nil
}
