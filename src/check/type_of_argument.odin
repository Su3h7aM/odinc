package check

import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

// A type-valued operand where a value of the target is expected, as official check_assignment reports it. The
// typeid suggestion applies only to an `any` target; notes follow it verbatim.
@(private = "package")
expression_type_context_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	target: types.Type_Id,
	type: types.Type_Id,
	construct: string,
	notes: string = "",
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf("Cannot assign '%s', a type, to %s", record_type_name(store, type, allocator), construct, allocator = allocator)
	if target != types.TYPE_NONE && types.get(store, target).kind == .Any {
		reason = fmt.aprintf("%s\n\tSuggestion: 'typeid_of(%s)'%s", reason, expression_text(file, node), notes, allocator = allocator)
	}
	return expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
}

// A type-valued operand that is not a typeid argument, as official check_assignment reports it.
@(private = "package")
expression_type_argument_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	target: types.Type_Id,
	type: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	return expression_type_context_failure(checker, view, scope, node, target, type, "a procedure argument")
}

// A runtime value initializing a variable of a different declared type, as official check_assignment reports it.
@(private = "package")
expression_value_initializer_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	target: types.Type_Id,
	source: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf(
		"Cannot assign value '%s' of type '%s' to '%s' in a variable declaration",
		expression_text(file, node),
		record_type_name(store, source, allocator),
		record_type_name(store, target, allocator),
		allocator = allocator,
	)
	return expression_failure(checker, view, scope, node, .Conversion, reason)
}

// Arithmetic and bitwise operands of different types, reported at the operator as official check_binary_expr does.
@(private = "package")
expression_binary_mismatch_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	operator: syntax.Token,
	left: types.Type_Id,
	right: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf(
		"Mismatched types in binary expression '%s' : '%s' vs '%s'",
		expression_text(file, node),
		types.type_text(store, left, allocator),
		types.type_text(store, right, allocator),
		allocator = allocator,
	)
	append(
		&checker.diagnostics,
		Expression_Diagnostic{kind = .Mismatched_Types, source = {checker.views[view].file, operator.start, operator.end}, reason = reason},
	) or_return
	info = expression_poison(scope)
	expression_store(checker, view, node, info)
	return info, nil
}

// Comparison operands that are not assignable to each other, as official check_comparison reports them.
@(private = "package")
expression_comparison_mismatch_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	left: types.Type_Id,
	right: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf(
		"Cannot compare expression. Mismatched types '%s' and '%s'.",
		types.type_text(store, left, allocator),
		types.type_text(store, right, allocator),
		allocator = allocator,
	)
	return expression_failure(checker, view, scope, node, .Mismatched_Types, reason)
}

// A runtime value passed to a typeid parameter, as official check_assignment reports it.
@(private = "package")
expression_value_argument_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	target: types.Type_Id,
	source: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf(
		"Cannot assign value '%s' of type '%s' to '%s' in a procedure argument",
		expression_text(file, node),
		record_type_name(store, source, allocator),
		record_type_name(store, target, allocator),
		allocator = allocator,
	)
	return expression_failure(checker, view, scope, node, .Conversion, reason)
}

// A type-valued operand whose context names no target, as official check_expr_with_type_hint reports it.
@(private = "package")
expression_type_ambiguous_failure :: proc(checker: ^Expression_Checker, view: View_Id, scope: Scope_Id, node: syntax.Node_Index) -> (err: Resolve_Error) {
	file := checker.type_checker.files[checker.views[view].file]
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf("'%s' is not an expression but a type, in this context it is ambiguous", expression_text(file, node), allocator = allocator)
	_, err = expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
	return err
}

// A type-valued initializer of a local variable, as official check_decl reports it. The inference note
// applies only when the variable has no declared type.
@(private = "package")
expression_type_variable_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	type: types.Type_Id,
	variable_name: string,
	inferred: bool,
) -> (
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf("Cannot assign a type '%s' to variable '%s'", record_type_name(store, type, allocator), variable_name, allocator = allocator)
	if inferred {
		reason = fmt.aprintf(
			"%s\n\tThe type of the variable '%s' cannot be inferred as a type and does not have a default type",
			reason,
			variable_name,
			allocator = allocator,
		)
	}
	_, err = expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
	return err
}
