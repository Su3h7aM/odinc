package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

// An enum member is an integer constant of the enum type. `.Member` takes its enum from the hint.
@(private = "package")
expression_implicit_selector :: proc(
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
	store := checker.type_checker.store
	if hint == 0 || types.get(store, types.resolve_named(store, hint)).kind != .Enum {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	field := syntax.node_payload(file.ast, node, syntax.Implicit_Selector_Expr).field
	return expression_enum_member(checker, view, scope, node, hint, expression_text(file, field))
}

@(private = "package")
expression_enum_member :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	enum_type: types.Type_Id,
	name: string,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file_id := checker.views[view].file
	members, found := checker.type_checker.enum_members[types.resolve_named(checker.type_checker.store, enum_type)]
	if !found { return expression_failure(checker, view, scope, node, .Unsupported) }
	for member in members {
		if member.name != name { continue }
		value: big.Int
		defer big.destroy(&value)
		if set_error := big.set(&value, member.value); set_error != nil {
			expression_constant_failure(checker, file_id, node, set_error) or_return
			return expression_poison(scope), nil
		}
		constant, constant_error := constant_pool_intern_integer(checker.constants, &value, enum_type)
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = enum_type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	return expression_failure(checker, view, scope, node, .Undeclared_Name)
}
