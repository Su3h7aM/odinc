package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Raw machine operations of base:intrinsics. Their operands and results have fixed types, so they are checked here
// rather than by an intrinsic shape.
@(private = "package")
target_op_kind :: proc(kind: Builtin_Kind) -> bool {
	return kind == .Read_Cycle_Counter || kind == .X86_Cpuid || kind == .X86_Xgetbv || kind == .Valgrind_Client_Request || simd_target_op_kind(kind)
}

@(private = "package")
simd_target_op_kind :: proc(kind: Builtin_Kind) -> bool {
	return(
		kind == .X86_Aesenc ||
		kind == .X86_Aesenclast ||
		kind == .X86_Aesimc ||
		kind == .X86_Aeskeygenassist ||
		kind == .X86_Aesdec ||
		kind == .X86_Aesdeclast ||
		kind == .X86_Pclmulqdq ||
		kind == .X86_Sha256msg1 ||
		kind == .X86_Sha256msg2 ||
		kind == .X86_Sha256rnds2 \
	)
}

// 128-bit operations take and return `#simd[16]u8`. The immediate of AESKEYGENASSIST must be a constant.
@(private = "package")
expression_simd_target_op :: proc(
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
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	byte_type := types.sized_integer(store, 1, false)
	vector_type := types.intern(store, types.Type{kind = .Simd_Vector, elem = byte_type, count = 16})
	operand_count := 2
	if kind == .X86_Aesimc { operand_count = 1 }
	if kind == .X86_Pclmulqdq { operand_count = 3 }
	if kind == .X86_Sha256rnds2 { operand_count = 3 }
	if ellipsis || len(arguments) != operand_count { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operands := make([]Operand, len(arguments), allocator) or_return
	for argument, index in arguments {
		is_immediate := kind == .X86_Aeskeygenassist && index == 1 || kind == .X86_Pclmulqdq && index == 2
		expected := byte_type if is_immediate else vector_type
		value := check_expression(checker, view, scope, argument, expected) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.type != expected || is_immediate && value.mode != .Constant {
			return expression_failure(checker, view, scope, argument, .Invalid_Operand)
		}
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = vector_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "package")
expression_target_op :: proc(
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
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	u32_type := types.sized_integer(store, 4, false)
	if simd_target_op_kind(kind) {
		return expression_simd_target_op(checker, view, scope, node, builtin, kind, arguments, ellipsis)
	}
	i64_type := types.sized_integer(store, 8, true)
	operand_count := 0
	operand_type := u32_type
	results: []types.Type_Id
	#partial switch kind {
	case .X86_Cpuid:
		operand_count = 2
		results = make([]types.Type_Id, 4, allocator) or_return
	case .X86_Xgetbv:
		operand_count = 1
		results = make([]types.Type_Id, 2, allocator) or_return
	case .Valgrind_Client_Request:
		operand_count = 7
		operand_type = checker.config.uintptr
	}
	for &result in results { result = u32_type }
	if ellipsis || len(arguments) != operand_count { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operands := make([]Operand, len(arguments), allocator) or_return
	for argument, index in arguments {
		value := check_expression(checker, view, scope, argument, operand_type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.type != operand_type { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands, results = results})) or_return
	if kind == .Read_Cycle_Counter {
		return Expression_Info{type = i64_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	if kind == .Valgrind_Client_Request {
		return Expression_Info{type = checker.config.uintptr, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil
}
