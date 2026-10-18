package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Operand and result shapes of the intrinsics that the checker plans as `Builtin_Plan`s. An explicit-order
// variant takes its memory orders after the value operands, as `intrinsic_order_count` gives.
Intrinsic_Shape :: enum u8 {
	None,
	Integer_Unary, // (x: T) -> T, T integer
	Value_Pair, // (x: T, expected: T) -> T
	Overflow, // (x, y: T) -> (T, bool), T integer
	Load, // (dst: ^T) -> T
	Store, // (dst: ^T, val: T)
	Update, // (dst: ^T, val: T) -> T, the old value
	Compare_Exchange, // (dst: ^T, old, new: T) -> (T, bool)
	Fence, // ()
	Bytes_Copy, // (dst, src: rawptr, len: int)
	Bytes_Zero, // (ptr: rawptr, len: int)
}

@(private = "package")
intrinsic_shape :: proc(kind: Builtin_Kind) -> Intrinsic_Shape {
	if shape := memory_misc_shape(kind); shape != .None { return shape }
	#partial switch kind {
	case .Count_Ones, .Count_Zeros, .Count_Leading_Zeros, .Count_Trailing_Zeros, .Reverse_Bits, .Byte_Swap:
		return .Integer_Unary
	case .Expect:
		return .Value_Pair
	case .Overflow_Add, .Overflow_Sub, .Overflow_Mul:
		return .Overflow
	case .Volatile_Load, .Atomic_Load, .Atomic_Load_Explicit, .Unaligned_Load:
		return .Load
	case .Volatile_Store, .Atomic_Store, .Atomic_Store_Explicit:
		return .Store
	case .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Nand, .Atomic_Or, .Atomic_Xor, .Atomic_Exchange:
		return .Update
	case .Atomic_Add_Explicit,
	     .Atomic_Sub_Explicit,
	     .Atomic_And_Explicit,
	     .Atomic_Nand_Explicit,
	     .Atomic_Or_Explicit,
	     .Atomic_Xor_Explicit,
	     .Atomic_Exchange_Explicit:
		return .Update
	case .Atomic_Compare_Exchange_Strong, .Atomic_Compare_Exchange_Weak:
		return .Compare_Exchange
	case .Atomic_Compare_Exchange_Strong_Explicit, .Atomic_Compare_Exchange_Weak_Explicit:
		return .Compare_Exchange
	case .Atomic_Thread_Fence, .Atomic_Signal_Fence:
		return .Fence
	case .Mem_Copy, .Mem_Copy_Non_Overlapping:
		return .Bytes_Copy

	}
	return .None
}

// The memory orders that follow the value operands: one for a single-order operation, two for a compare-exchange.
@(private = "package")
intrinsic_order_count :: proc(kind: Builtin_Kind) -> int {
	#partial switch kind {
	case .Atomic_Compare_Exchange_Strong_Explicit, .Atomic_Compare_Exchange_Weak_Explicit:
		return 2
	case .Atomic_Load_Explicit, .Atomic_Store_Explicit, .Atomic_Add_Explicit, .Atomic_Sub_Explicit, .Atomic_And_Explicit, .Atomic_Nand_Explicit:
		return 1
	case .Atomic_Or_Explicit, .Atomic_Xor_Explicit, .Atomic_Exchange_Explicit, .Atomic_Thread_Fence, .Atomic_Signal_Fence:
		return 1
	}
	return 0
}

@(private = "file")
intrinsic_argument_count :: proc(shape: Intrinsic_Shape) -> int {
	switch shape {
	case .None, .Fence:
		return 0
	case .Integer_Unary, .Load:
		return 1
	case .Value_Pair, .Overflow, .Store, .Update, .Bytes_Zero:
		return 2
	case .Compare_Exchange, .Bytes_Copy:
		return 3
	}
	return 0
}

// The `intrinsics.Atomic_Memory_Order` type, or 0 when the intrinsics package does not declare it.
@(private = "file")
atomic_order_type :: proc(checker: ^Expression_Checker) -> (order: types.Type_Id, err: Resolve_Error) {
	resolver := checker.type_checker.resolver
	for intrinsics_package in checker.packages {
		if intrinsics_package.kind != .Intrinsics { continue }
		entity := scope_lookup_current(resolver.scopes, intrinsics_package.scope, "Atomic_Memory_Order")
		if entity == 0 { return 0, nil }
		state, resolve_error := resolve_entity(resolver, entity)
		if resolve_error != nil { return 0, resolve_error }
		if state != .Resolved { return 0, nil }
		return entity_get(resolver.scopes, entity).type, nil
	}
	return 0, nil
}

// Each value operand is checked with the type its shape requires, so untyped constants take that type; a typed operand of another type is rejected.
// Memory-order operands follow the values and must have the `Atomic_Memory_Order` type.
@(private = "package")
expression_intrinsic_call :: proc(
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
	shape := intrinsic_shape(kind)
	value_count := intrinsic_argument_count(shape)
	order_count := intrinsic_order_count(kind)
	if ellipsis || len(arguments) != value_count + order_count {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	store := checker.type_checker.store
	order_type := types.Type_Id(0)
	if order_count > 0 {
		order_type = atomic_order_type(checker) or_return
		if order_type == 0 { return expression_failure(checker, view, scope, node, .Unsupported) }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(arguments), allocator) or_return
	element: types.Type_Id
	int_type := checker.default_integer
	for argument, index in arguments {
		if index >= value_count {
			order := check_expression(checker, view, scope, argument, order_type) or_return
			if order.state == .Invalid { return expression_poison(scope), nil }
			if order.type != order_type { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
			operands[index] = Operand(Expression_Ref{view, argument})
			continue
		}
		hint := types.Type_Id(0)
		switch shape {
		case .Integer_Unary:
			hint = checker.default_integer
		case .Overflow:
			hint = element if index == 1 else checker.default_integer
		case .Value_Pair:
			hint = element if index == 1 else 0
		case .Store, .Update, .Compare_Exchange:
			hint = element if index > 0 else 0
		case .Bytes_Copy, .Bytes_Zero:
			hint = int_type if index == value_count - 1 else 0
		case .None, .Load, .Fence:
		}
		value := check_expression(checker, view, scope, argument, hint) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		descriptor := types.get(store, types.resolve_named(store, value.type))
		valid := false
		switch shape {
		case .Integer_Unary:
			valid = descriptor.kind == .Integer
			element = value.type
		case .Overflow:
			if index == 0 {
				valid = descriptor.kind == .Integer
				element = value.type
			} else {
				valid = value.type == element
			}
		case .Value_Pair:
			valid = index == 0 || value.type == element
			if index == 0 { element = value.type }
		case .Load, .Store, .Update, .Compare_Exchange:
			if index == 0 {
				valid = descriptor.kind == .Pointer
				if valid { element = descriptor.elem }
			} else {
				valid = value.type == element
			}
		case .Bytes_Copy, .Bytes_Zero:
			if index == value_count - 1 {
				valid = value.type == int_type
			} else {
				valid = descriptor.kind == .Raw_Pointer || descriptor.kind == .Pointer || descriptor.kind == .Multi_Pointer
			}
		case .None, .Fence:
		}
		if !valid { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	results: []types.Type_Id
	#partial switch shape {
	case .Overflow, .Compare_Exchange:
		results = make([]types.Type_Id, 2, allocator) or_return
		results[0], results[1] = element, checker.boolean
	}
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands, results = results})) or_return
	info = Expression_Info {
		mode  = .No_Value,
		plan  = plan,
		scope = scope,
		state = .Checked,
	}
	#partial switch shape {
	case .Integer_Unary, .Value_Pair, .Load, .Update:
		info.type = element
		info.mode = .Value
	}
	return info, nil
}
