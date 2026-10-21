package check

import "base:runtime"
import "core:mem"
import "oc:syntax"
import "oc:types"

// intrinsics.type_hasher_proc(T): the generated hasher of T, the same procedure map keys of type T use.
@(private = "package")
expression_type_hasher_proc :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_unsupported(checker, view, scope, node, "Type_Hasher_Proc_Arguments") }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.mode != .Type { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	store := checker.type_checker.store
	resolved := types.resolve_named(store, operand.type)
	if !generator_supported(store, resolved) { return expression_unsupported(checker, view, scope, node, "Type_Hasher_Proc_Type") }
	helpers_resolved, helper_error := expression_resolve_map_helpers(checker)
	if helper_error != nil { return {}, helper_error }
	if !helpers_resolved { return expression_unsupported(checker, view, scope, node, "Type_Hasher_Proc_Helpers") }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	signature, signature_error := map_generated_signature(store, .Hasher, allocator)
	if signature_error != nil { return {}, signature_error }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, type = resolved})) or_return
	return Expression_Info{type = signature, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// Generates the hasher of every type_hasher_proc plan. Runs at publish time, which rebuilds the procedure table.
@(private = "package")
expression_checker_publish_type_hashers :: proc(checker: ^Expression_Checker) -> runtime.Allocator_Error {
	for plan in checker.plans {
		requested, is_builtin := plan.(Builtin_Plan)
		if !is_builtin || checker.builtin_kinds[requested.builtin] != .Type_Hasher_Proc { continue }
		map_generated_procedure(checker, .Hasher, requested.type) or_return
	}
	return nil
}
