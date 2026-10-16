package check

import "base:runtime"
import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

// Declared names of procedures in package base:intrinsics that the checker lowers as builtins.
intrinsic_builtin_kind :: proc(name: string) -> Builtin_Kind {
	switch name {
	case "syscall":
		return .Syscall
	}
	return .None
}

@(private = "package")
expression_builtin_id :: proc(checker: ^Expression_Checker, kind: Builtin_Kind) -> (id: Builtin_Id, err: runtime.Allocator_Error) {
	if len(checker.builtin_kinds) == 0 { append(&checker.builtin_kinds, Builtin_Kind.None) or_return }
	append(&checker.builtin_kinds, kind) or_return
	return Builtin_Id(len(checker.builtin_kinds) - 1), nil
}

@(private = "package")
expression_in_intrinsics :: proc(checker: ^Expression_Checker, package_id: Package_Id) -> bool {
	return int(package_id) < len(checker.packages) && checker.packages[package_id].kind == .Intrinsics
}

// A bodiless procedure of base:intrinsics becomes a builtin entity. Unlisted names remain unsupported.
@(private = "package")
expression_intrinsic_declaration :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	id: Entity_Id,
	view: View_Id,
	node: syntax.Node_Index,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	kind := intrinsic_builtin_kind(entity_get(resolver.scopes, id).name)
	if kind == .None {
		expression_failure(checker, view, entity_get(resolver.scopes, id).scope, node, .Unsupported) or_return
		return false, nil
	}
	builtin := expression_builtin_id(checker, kind) or_return
	binding := entity_get(resolver.scopes, id)
	binding.kind = .Builtin
	binding.data = builtin
	return true, nil
}

// A syscall takes its number and up to six words; every argument is converted to uintptr by its own row.
@(private = "package")
expression_builtin_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if callee.state == .Invalid { return expression_poison(scope), nil }
	file := checker.type_checker.files[file_id]
	call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
	builtin := entity_get(checker.type_checker.resolver.scopes, callee.entity).data.(Builtin_Id)
	if kind := checker.builtin_kinds[builtin]; kind == .Len || kind == .Cap {
		return expression_length(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] != .Syscall || call.ellipsis.kind != .Invalid || len(arguments) < 1 || len(arguments) > 7 {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	word := checker.config.uintptr
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(arguments), allocator) or_return
	for argument, index in arguments {
		value := check_expression(checker, view, scope, argument, word) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = word, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// len and cap of a fixed array are constants. len of a slice or string is read from its header during lowering.
@(private = "file")
expression_length :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_failure(checker, view, scope, node, .Unsupported) }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, operand.type))
	#partial switch descriptor.kind {
	case .Array:
		value: big.Int
		defer big.destroy(&value)
		if set_error := big.set(&value, descriptor.count); set_error != nil {
			expression_constant_failure(checker, checker.views[view].file, node, set_error) or_return
			return expression_poison(scope), nil
		}
		constant, constant_error := constant_pool_intern_integer(checker.constants, &value, checker.default_integer)
		if constant_error != nil {
			expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = checker.default_integer, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	case .Slice, .String:
		if kind == .Cap { return expression_failure(checker, view, scope, node, .Unsupported) }
		allocator := mem.dynamic_arena_allocator(&checker.arena)
		operands := make([]Operand, 1, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
		return Expression_Info{type = checker.default_integer, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	return expression_failure(checker, view, scope, node, .Invalid_Operand)
}
