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
	case "trap":
		return .Trap
	case "count_ones":
		return .Count_Ones
	case "count_zeros":
		return .Count_Zeros
	case "count_leading_zeros":
		return .Count_Leading_Zeros
	case "count_trailing_zeros":
		return .Count_Trailing_Zeros
	case "reverse_bits":
		return .Reverse_Bits
	case "byte_swap":
		return .Byte_Swap
	case "expect":
		return .Expect
	case "volatile_load":
		return .Volatile_Load
	case "volatile_store":
		return .Volatile_Store
	case "atomic_load":
		return .Atomic_Load
	case "atomic_store":
		return .Atomic_Store
	case "atomic_add":
		return .Atomic_Add
	case "atomic_sub":
		return .Atomic_Sub
	case "atomic_and":
		return .Atomic_And
	case "atomic_or":
		return .Atomic_Or
	case "atomic_xor":
		return .Atomic_Xor
	case "atomic_exchange":
		return .Atomic_Exchange
	case "atomic_compare_exchange_strong":
		return .Atomic_Compare_Exchange_Strong
	case "atomic_compare_exchange_weak":
		return .Atomic_Compare_Exchange_Weak
	case "atomic_load_explicit":
		return .Atomic_Load_Explicit
	case "atomic_store_explicit":
		return .Atomic_Store_Explicit
	case "atomic_add_explicit":
		return .Atomic_Add_Explicit
	case "atomic_sub_explicit":
		return .Atomic_Sub_Explicit
	case "atomic_and_explicit":
		return .Atomic_And_Explicit
	case "atomic_or_explicit":
		return .Atomic_Or_Explicit
	case "atomic_xor_explicit":
		return .Atomic_Xor_Explicit
	case "atomic_exchange_explicit":
		return .Atomic_Exchange_Explicit
	case "atomic_compare_exchange_strong_explicit":
		return .Atomic_Compare_Exchange_Strong_Explicit
	case "atomic_compare_exchange_weak_explicit":
		return .Atomic_Compare_Exchange_Weak_Explicit
	case "atomic_thread_fence":
		return .Atomic_Thread_Fence
	case "atomic_signal_fence":
		return .Atomic_Signal_Fence
	case "overflow_add":
		return .Overflow_Add
	case "overflow_sub":
		return .Overflow_Sub
	case "overflow_mul":
		return .Overflow_Mul
	case "mem_copy":
		return .Mem_Copy
	case "mem_copy_non_overlapping":
		return .Mem_Copy_Non_Overlapping
	case "mem_zero":
		return .Mem_Zero
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
	if kind := checker.builtin_kinds[builtin]; kind == .Min || kind == .Max || kind == .Abs || kind == .Clamp {
		return expression_numeric_builtin(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] == .Trap {
		if len(arguments) != 0 || call.ellipsis.kind != .Invalid { return expression_failure(checker, view, scope, node, .Unsupported) }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin})) or_return
		return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Size_Of || kind == .Align_Of {
		return expression_layout_query(checker, view, scope, node, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Len || kind == .Cap {
		return expression_length(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; intrinsic_shape(kind) != .None {
		return expression_intrinsic_call(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
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

// min, max, abs and clamp take runtime operands of one integer or float type; constant operands fold in no builtin yet.
@(private = "file")
expression_numeric_builtin :: proc(
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
	store := checker.type_checker.store
	count := 2
	if kind == .Abs { count = 1 } else if kind == .Clamp { count = 3 }
	if len(arguments) != count || ellipsis { return expression_failure(checker, view, scope, node, .Unsupported) }
	first := check_expression(checker, view, scope, arguments[0]) or_return
	if first.state == .Invalid { return expression_poison(scope), nil }
	first_kind := types.get(store, types.resolve_named(store, first.type)).kind
	if !(conversion_integer(first_kind) || first_kind == .Float) { return expression_failure(checker, view, scope, node, .Unsupported) }
	constant := first.mode == .Constant
	for index in 1 ..< count {
		operand := check_expression(checker, view, scope, arguments[index], first.type) or_return
		if operand.state == .Invalid { return expression_poison(scope), nil }
		if operand.type != first.type { return expression_failure(checker, view, scope, node, .Unsupported) }
		constant = constant && operand.mode == .Constant
	}
	if constant {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, count, allocator) or_return
	for argument, index in arguments { operands[index] = Operand(Expression_Ref{view, argument}) }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = first.type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// size_of and align_of fold to the target layout of the operand's type, as an untyped integer does in the official compiler.
@(private = "file")
expression_layout_query :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
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
	size, alignment, layout_error := types.layout(checker.type_checker.store, operand.type)
	if layout_error != .None { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	bytes := size
	if kind == .Align_Of { bytes = alignment }
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, bytes); set_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, set_error) or_return
		return expression_poison(scope), nil
	}
	constant, constant_error := constant_pool_intern_integer(checker.constants, &value, checker.default_integer)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = checker.default_integer, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
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
