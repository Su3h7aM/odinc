package check

import "core:fmt"
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
	field := syntax.node_payload(file.ast, node, syntax.Implicit_Selector_Expr).field
	name := expression_text(file, field)
	fmt.eprintf("SELECTOR_HINT %s:%d name=%q hint=%d\n", file.display_path, file.ast.nodes[node].start, name, hint)
	if hint != 0 {
		hint_descriptor := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, hint))^
		fmt.eprintf("SELECTOR_HINTKIND %v\n", hint_descriptor.kind)
	}
	if enum_type, found := implicit_selector_enum(checker, hint, name); found {
		return expression_enum_member(checker, view, scope, node, enum_type, name)
	}
	return expression_unsupported(checker, view, scope, node, "Implicit_Selector_Type")
}

// The enum an implicit selector `.name` takes from hint: the enum itself, or the one enum variant of a union that has the member.
@(private = "file")
implicit_selector_enum :: proc(checker: ^Expression_Checker, hint: types.Type_Id, name: string) -> (enum_type: types.Type_Id, found: bool) {
	if hint == 0 { return 0, false }
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, hint))
	if descriptor.kind == .Enum { return hint, true }
	if descriptor.kind != .Union { return 0, false }
	matches := 0
	for variant in descriptor.variants {
		resolved := types.resolve_named(store, variant)
		if types.get(store, resolved).kind != .Enum || !enum_has_member(checker, resolved, name) { continue }
		enum_type = variant
		matches += 1
	}
	return enum_type, matches == 1
}

@(private = "file")
enum_has_member :: proc(checker: ^Expression_Checker, enum_type: types.Type_Id, name: string) -> bool {
	members, found := checker.type_checker.enum_members[enum_type]
	if !found { return false }
	for member in members {
		if member.name == name { return true }
	}
	return false
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
	if !found { return expression_unsupported(checker, view, scope, node, "Enum_Members") }
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
