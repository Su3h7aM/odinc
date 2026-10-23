package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Matrix compiler intrinsics. Results are values, never constants.
@(private = "package")
expression_matrix_builtin :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if ellipsis { return expression_unsupported(checker, view, scope, node, "Matrix_Builtin_Ellipsis") }
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operand_nodes := arguments
	want := len(arguments)
	if kind == .Hadamard_Product || kind == .Outer_Product { want = 2 }
	if kind == .Matrix_Flatten || kind == .Transpose { want = 1 }
	if len(arguments) != want { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operands := make([]Operand, len(operand_nodes), allocator) or_return
	infos := make([]Expression_Info, len(operand_nodes), allocator) or_return
	for argument, index in operand_nodes {
		value := check_expression(checker, view, scope, argument) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if !expression_value(value) { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		operands[index] = Operand(Expression_Ref{view, argument})
		infos[index] = value
	}
	bases := make([]types.Type, len(operand_nodes), allocator) or_return
	for value, index in infos {
		bases[index] = types.get(store, conversion_base_type(store, value.type))^
	}
	result: types.Type_Id
	#partial switch kind {
	case .Hadamard_Product:
		left, right := bases[0], bases[1]
		if left.kind != right.kind || (left.kind != .Matrix && left.kind != .Array) {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		if left.elem != right.elem || left.count != right.count || left.upper_bound != right.upper_bound || left.row_major != right.row_major {
			return expression_failure(checker, view, scope, node, .Mismatched_Types)
		}
		if !matrix_element_valid(store, left.elem) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		result = matrix_hint_type(store, infos[0].type, hint)
	case .Matrix_Flatten:
		base := bases[0]
		if base.kind == .Array {
			result = matrix_hint_type(store, infos[0].type, hint)
		} else if base.kind == .Matrix {
			result = matrix_hint_type(store, types.intern(store, types.Type{kind = .Array, elem = base.elem, count = base.count * base.upper_bound}), hint)
		} else {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
	case .Transpose:
		base := bases[0]
		if base.kind != .Matrix { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		result = matrix_hint_type(
			store,
			types.intern(store, types.Type{kind = .Matrix, elem = base.elem, count = base.upper_bound, upper_bound = base.count, row_major = base.row_major}),
			hint,
		)
	case .Outer_Product:
		left, right := bases[0], bases[1]
		if left.kind != .Array || right.kind != .Array { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		if left.elem != right.elem { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
		if left.count <= 0 || right.count <= 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		if left.count * right.count > MATRIX_ELEMENT_COUNT_MAX { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		if !matrix_element_valid(store, left.elem) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		result = matrix_hint_type(
			store,
			types.intern(store, types.Type{kind = .Matrix, elem = left.elem, count = left.count, upper_bound = right.count}),
			hint,
		)
	case:
		return expression_unsupported(checker, view, scope, node, "Matrix_Builtin_Kind")
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}
