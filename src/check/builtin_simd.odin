package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
simd_reduction_kind :: proc(kind: Builtin_Kind) -> bool {
	#partial switch kind {
	case .Simd_Reduce_Or,
	     .Simd_Reduce_And,
	     .Simd_Reduce_Xor,
	     .Simd_Reduce_Min,
	     .Simd_Reduce_Max,
	     .Simd_Reduce_Add_Bisect,
	     .Simd_Reduce_Add_Ordered,
	     .Simd_Reduce_Add_Pairs,
	     .Simd_Reduce_Mul_Bisect,
	     .Simd_Reduce_Mul_Ordered,
	     .Simd_Reduce_Mul_Pairs:
		return true
	}
	return false
}

@(private = "package")
expression_simd_reduction :: proc(
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
	if ellipsis || len(arguments) != 1 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	value := check_expression(checker, view, scope, arguments[0], 0) or_return
	if value.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	vector := types.get(store, types.resolve_named(store, value.type))
	if vector.kind != .Simd_Vector { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	element := types.get(store, types.resolve_named(store, vector.elem))
	kind := checker.builtin_kinds[builtin]
	bitwise := kind == .Simd_Reduce_Or || kind == .Simd_Reduce_And || kind == .Simd_Reduce_Xor
	valid := element.kind == .Integer || (element.kind == .Bool if bitwise else element.kind == .Float)
	if !valid { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 1, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, arguments[0]})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = vector.elem, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}
