package check

import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

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
	file := checker.type_checker.files[checker.views[view].file]
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf("Cannot assign '%s', a type, to a procedure argument", record_type_name(store, type, allocator), allocator = allocator)
	if types.get(store, target).kind == .Any {
		reason = fmt.aprintf("%s\n\tSuggestion: 'typeid_of(%s)'", reason, expression_text(file, node), allocator = allocator)
	}
	return expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
}

// A type-valued right-hand side of an assignment, as official check_assignment reports it.
@(private = "package")
expression_type_assignment_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	type: types.Type_Id,
) -> (
	err: Resolve_Error,
) {
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	store := checker.type_checker.store
	reason := fmt.aprintf("Cannot assign '%s', a type, to assignment", record_type_name(store, type, allocator), allocator = allocator)
	_, err = expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
	return err
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

// A package-level type-valued initializer, as official check_expr_with_type_hint reports it.
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
