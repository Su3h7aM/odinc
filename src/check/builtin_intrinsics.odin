package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Operand and result shapes of the intrinsics that the checker plans as `Builtin_Plan`s.
Intrinsic_Shape :: enum u8 {
	None,
	Integer_Unary, // (x: T) -> T, T integer
	Value_Pair, // (x: T, expected: T) -> T
	Load, // (dst: ^T) -> T
	Store, // (dst: ^T, val: T)
	Update, // (dst: ^T, val: T) -> T, the old value
	Bytes_Copy, // (dst, src: rawptr, len: int)
	Bytes_Zero, // (ptr: rawptr, len: int)
}

@(private = "package")
intrinsic_shape :: proc(kind: Builtin_Kind) -> Intrinsic_Shape {
	#partial switch kind {
	case .Count_Ones, .Count_Zeros, .Count_Leading_Zeros, .Count_Trailing_Zeros, .Reverse_Bits, .Byte_Swap:
		return .Integer_Unary
	case .Expect:
		return .Value_Pair
	case .Volatile_Load, .Atomic_Load:
		return .Load
	case .Volatile_Store, .Atomic_Store:
		return .Store
	case .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Exchange:
		return .Update
	case .Mem_Copy, .Mem_Copy_Non_Overlapping:
		return .Bytes_Copy
	case .Mem_Zero:
		return .Bytes_Zero
	}
	return .None
}

@(private = "file")
intrinsic_argument_count :: proc(shape: Intrinsic_Shape) -> int {
	switch shape {
	case .None:
		return 0
	case .Integer_Unary, .Load:
		return 1
	case .Value_Pair, .Store, .Update, .Bytes_Zero:
		return 2
	case .Bytes_Copy:
		return 3
	}
	return 0
}

// Each operand is checked with the type its shape requires, so untyped constants take that type; a typed operand of another type is rejected.
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
	if ellipsis || len(arguments) != intrinsic_argument_count(shape) {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(arguments), allocator) or_return
	element: types.Type_Id
	int_type := checker.default_integer
	for argument, index in arguments {
		hint := types.Type_Id(0)
		switch shape {
		case .Integer_Unary:
			hint = checker.default_integer
		case .Value_Pair:
			hint = element if index == 1 else checker.default_integer
		case .Store, .Update:
			hint = element if index == 1 else 0
		case .Bytes_Copy, .Bytes_Zero:
			hint = int_type if index == len(arguments) - 1 else 0
		case .None, .Load:
		}
		value := check_expression(checker, view, scope, argument, hint) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		descriptor := types.get(store, types.resolve_named(store, value.type))
		valid := false
		switch shape {
		case .Integer_Unary:
			valid = descriptor.kind == .Integer
			element = value.type
		case .Value_Pair:
			valid = index == 0 || value.type == element
			if index == 0 { element = value.type }
		case .Load, .Store, .Update:
			if index == 0 {
				valid = descriptor.kind == .Pointer
				if valid { element = descriptor.elem }
			} else {
				valid = value.type == element
			}
		case .Bytes_Copy, .Bytes_Zero:
			if index == len(arguments) - 1 {
				valid = value.type == int_type
			} else {
				valid = descriptor.kind == .Raw_Pointer || descriptor.kind == .Pointer || descriptor.kind == .Multi_Pointer
			}
		case .None:
		}
		if !valid { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
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
