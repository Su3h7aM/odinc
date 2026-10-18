package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Raw machine operations of base:intrinsics. Their operands and results have fixed types, so they are checked here
// rather than by an intrinsic shape.
@(private = "package")
target_op_kind :: proc(kind: Builtin_Kind) -> bool {
	return kind == .Read_Cycle_Counter || kind == .X86_Cpuid || kind == .X86_Xgetbv
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
	i64_type := types.sized_integer(store, 8, true)
	operand_count := 0
	results: []types.Type_Id
	#partial switch kind {
	case .X86_Cpuid:
		operand_count = 2
		results = make([]types.Type_Id, 4, allocator) or_return
	case .X86_Xgetbv:
		operand_count = 1
		results = make([]types.Type_Id, 2, allocator) or_return
	}
	for &result in results { result = u32_type }
	if ellipsis || len(arguments) != operand_count { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operands := make([]Operand, len(arguments), allocator) or_return
	for argument, index in arguments {
		value := check_expression(checker, view, scope, argument, u32_type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.type != u32_type { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands, results = results})) or_return
	if kind == .Read_Cycle_Counter {
		return Expression_Info{type = i64_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil
}
