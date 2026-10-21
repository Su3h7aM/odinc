package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

// `m[row, column]` selects one element. A constant index is bounds-checked here; a runtime index keeps its
// operand and is checked by lowering, following the file bounds-check policy like array indexing.
Matrix_Index_Plan :: struct {
	base:   Operand,
	row:    Operand,
	column: Operand,
	policy: Check_Policy,
}

// `m[k]` selects one storage vector: a column for column-major matrices and a row for `#row_major` ones.
Matrix_Vector_Plan :: struct {
	base:   Operand,
	index:  Operand,
	policy: Check_Policy,
}

// Storage index of the element at `position` in row-major reading order, as matrix literals are written.
@(private = "package")
matrix_storage_index :: proc(descriptor: types.Type, position: int) -> int {
	if descriptor.row_major { return position }
	columns := int(descriptor.upper_bound)
	return (position % columns) * int(descriptor.count) + position / columns
}

// Checks one axis index against its length. A constant index is bounds-checked here; a runtime index keeps
// its operand and is checked by lowering.
@(private = "file")
matrix_index_operand :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	index_node: syntax.Node_Index,
	length: i64,
) -> (
	operand: Operand,
	constant: bool,
	failed: bool,
	err: Resolve_Error,
) {
	position := check_expression(checker, view, scope, index_node, checker.default_integer) or_return
	if position.state == .Invalid { return nil, false, true, nil }
	if position.mode == .Constant {
		integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
		index, index_error := big.int_get_i64(&integer)
		if index_error != nil || index < 0 || index >= length {
			_, err = expression_failure(checker, view, scope, index_node, .Invalid_Operand)
			return nil, false, true, err
		}
		return Operand(Expression_Ref{view, index_node}), true, false, nil
	}
	return Operand(Expression_Ref{view, index_node}), false, false, nil
}

@(private = "package")
expression_matrix_index :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	access := syntax.node_payload(file.ast, node, syntax.Matrix_Index_Expr)
	base := check_expression(checker, view, scope, access.expr) or_return
	if base.state == .Invalid { return expression_poison(scope), nil }
	if base.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, access.expr, base.mode) }
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, base.type))^
	if descriptor.kind != .Matrix { return expression_unsupported(checker, view, scope, node, "Matrix_Index_Base") }
	row, row_constant, row_failed := matrix_index_operand(checker, view, scope, access.row_index, descriptor.count) or_return
	if row_failed { return expression_poison(scope), nil }
	column, column_constant, column_failed := matrix_index_operand(checker, view, scope, access.column_index, descriptor.upper_bound) or_return
	if column_failed { return expression_poison(scope), nil }
	mode := Addressing_Mode.Variable if base.mode == .Variable else .Value
	policy := Check_Policy.Enabled if checker.unchecked_depth == 0 else Check_Policy.Disabled
	if row_constant && column_constant { policy = .Disabled }
	if checker.type_checker.files[file_id].policy.bounds_check == .Disabled { policy = .Disabled }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Matrix_Index_Plan{base = Operand(Expression_Ref{view, access.expr}), row = row, column = column, policy = policy})) or_return
	return Expression_Info{type = descriptor.elem, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}

// Scalar operands keep their value: `*` broadcasts while any other operator reads a scaled identity.
Matrix_Binary_Plan :: struct {
	op:     syntax.Token_Kind,
	left:   Operand,
	right:  Operand,
	result: types.Type_Id,
}

@(private = "package")
expression_binary_matrix_involved :: proc(checker: ^Expression_Checker, left, right: Expression_Info) -> bool {
	if left.type == 0 || right.type == 0 { return false }
	store := checker.type_checker.store
	if types.get(store, types.resolve_named(store, left.type)).kind == .Matrix { return true }
	return types.get(store, types.resolve_named(store, right.type)).kind == .Matrix
}

// Mirrors the official `check_matrix_type_hint`: a result that fits the hint takes the hint type.
@(private)
matrix_hint_type :: proc(store: ^types.Store, computed, hint: types.Type_Id) -> types.Type_Id {
	if hint == 0 { return computed }
	if computed == hint { return hint }
	resolved := types.get(store, types.resolve_named(store, computed))^
	hinted := types.get(store, types.resolve_named(store, hint))^
	if resolved.kind == .Matrix && hinted.kind == .Matrix {
		if resolved.elem == hinted.elem &&
		   resolved.count == hinted.count &&
		   resolved.upper_bound == hinted.upper_bound &&
		   resolved.row_major == hinted.row_major {
			return hint
		}
	} else if resolved.kind == .Matrix && hinted.kind == .Array {
		if resolved.elem == hinted.elem &&
		   ((resolved.count == 1 && resolved.upper_bound == hinted.count) || (resolved.upper_bound == 1 && resolved.count == hinted.count)) {
			return hint
		}
	} else if resolved.kind == .Array && hinted.kind == .Array {
		if resolved.elem == hinted.elem && resolved.count == hinted.count { return hint }
	}
	return computed
}

@(private = "package")
expression_binary_matrix :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	binary: syntax.Binary_Expr,
	left, right: Expression_Info,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	operator := binary.op.kind
	#partial switch operator {
	case .Add_Eq:
		operator = .Add
	case .Sub_Eq:
		operator = .Sub
	case .Mul_Eq:
		operator = .Mul
	case .Quo_Eq:
		operator = .Quo
	case .Mod_Eq:
		operator = .Mod
	case .Mod_Mod_Eq:
		operator = .Mod_Mod
	case .And_Eq:
		operator = .And
	case .Or_Eq:
		operator = .Or
	case .Xor_Eq:
		operator = .Xor
	case .And_Not_Eq:
		operator = .And_Not
	case .Shl_Eq:
		operator = .Shl
	case .Shr_Eq:
		operator = .Shr
	}
	comparison := operator == .Cmp_Eq || operator == .Not_Eq
	#partial switch operator {
	case .Quo, .Mod, .Mod_Mod, .Shl, .Shr, .Cmp_And, .Cmp_Or, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		return expression_failure(checker, view, scope, node, .Invalid_Operator)
	}
	store := checker.type_checker.store
	left_base := types.get(store, types.resolve_named(store, left.type))^
	right_base := types.get(store, types.resolve_named(store, right.type))^
	if left_base.kind == .Matrix && right_base.kind == .Matrix {
		return expression_matrix_matrix(checker, view, scope, node, binary, operator, comparison, left, hint, left_base, right_base)
	}
	if left_base.kind == .Matrix || right_base.kind == .Matrix {
		left_matrix := left_base.kind == .Matrix
		if (left_matrix && right_base.kind == .Array) || (!left_matrix && left_base.kind == .Array) {
			return expression_matrix_vector_product(checker, view, scope, node, binary, operator, left, right, hint, left_base, right_base, left_matrix)
		}
		other_node := binary.right if left_matrix else binary.left
		other_info := right if left_matrix else left
		matrix_info := left if left_matrix else right
		matrix_base := left_base if left_matrix else right_base
		return expression_matrix_scalar(
			checker,
			view,
			scope,
			node,
			binary,
			other_node,
			operator,
			comparison,
			left_matrix,
			matrix_info,
			other_info,
			matrix_base,
		)
	}
	return expression_failure(checker, view, scope, node, .Invalid_Operator)
}

@(private = "file")
expression_matrix_matrix :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	binary: syntax.Binary_Expr,
	operator: syntax.Token_Kind,
	comparison: bool,
	left: Expression_Info,
	hint: types.Type_Id,
	left_base, right_base: types.Type,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	left_operand := Operand(Expression_Ref{view, binary.left})
	right_operand := Operand(Expression_Ref{view, binary.right})
	identical :=
		left_base.elem == right_base.elem &&
		left_base.count == right_base.count &&
		left_base.upper_bound == right_base.upper_bound &&
		left_base.row_major == right_base.row_major
	result := left.type
	if operator == .Mul {
		if left_base.elem != right_base.elem || left_base.upper_bound != right_base.count || left_base.row_major != right_base.row_major {
			return expression_failure(checker, view, scope, node, .Mismatched_Types)
		}
		if left_base.count * right_base.upper_bound > MATRIX_ELEMENT_COUNT_MAX {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		if !identical {
			result = types.intern(
				store,
				types.Type {
					kind = .Matrix,
					elem = left_base.elem,
					count = left_base.count,
					upper_bound = right_base.upper_bound,
					row_major = left_base.row_major,
				},
			)
		}
	} else {
		if !identical { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
		if comparison {
			plan := Plan_Id(len(checker.plans))
			append(&checker.plans, Plan(Matrix_Binary_Plan{op = operator, left = left_operand, right = right_operand, result = checker.boolean})) or_return
			return Expression_Info{type = checker.boolean, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
		}
		if operator == .And || operator == .Or || operator == .Xor || operator == .And_Not {
			if !conversion_integer(types.get(store, left_base.elem).kind) {
				return expression_failure(checker, view, scope, node, .Invalid_Operator)
			}
		}
	}
	result = matrix_hint_type(store, result, hint)
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Matrix_Binary_Plan{op = operator, left = left_operand, right = right_operand, result = result})) or_return
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_matrix_vector_product :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	binary: syntax.Binary_Expr,
	operator: syntax.Token_Kind,
	left, right: Expression_Info,
	hint: types.Type_Id,
	left_base, right_base: types.Type,
	left_matrix: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	if operator != .Mul { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
	matrix_base := left_base if left_matrix else right_base
	array_base := right_base if left_matrix else left_base
	array_info := right if left_matrix else left
	if matrix_base.elem != array_base.elem { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
	result := left.type
	if left_matrix {
		if matrix_base.upper_bound != array_base.count { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
		if matrix_base.count != array_base.count {
			result = types.intern(
				store,
				types.Type{kind = .Matrix, elem = matrix_base.elem, count = matrix_base.count, upper_bound = 1, row_major = matrix_base.row_major},
			)
		} else {
			result = array_info.type
		}
	} else {
		if array_base.count != matrix_base.count { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
		if matrix_base.upper_bound != array_base.count {
			result = types.intern(
				store,
				types.Type{kind = .Matrix, elem = matrix_base.elem, count = 1, upper_bound = matrix_base.upper_bound, row_major = matrix_base.row_major},
			)
		} else {
			result = array_info.type
		}
	}
	result = matrix_hint_type(store, result, hint)
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(
			Matrix_Binary_Plan {
				op = operator,
				left = Operand(Expression_Ref{view, binary.left}),
				right = Operand(Expression_Ref{view, binary.right}),
				result = result,
			},
		),
	) or_return
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_matrix_scalar :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	binary: syntax.Binary_Expr,
	scalar_node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	comparison: bool,
	matrix_left: bool,
	matrix_info, scalar_info: Expression_Info,
	matrix_base: types.Type,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	scalar_kind := types.get(store, types.resolve_named(store, scalar_info.type)).kind
	if operator == .And || operator == .Or || operator == .Xor || operator == .And_Not {
		if !conversion_integer(types.get(store, matrix_base.elem).kind) {
			return expression_failure(checker, view, scope, node, .Invalid_Operator)
		}
	}
	scalar := scalar_info
	if conversion_untyped(scalar_kind) {
		if matrix_base.count != matrix_base.upper_bound || !operand_assignable(checker, view, scalar_node, scalar, matrix_base.elem) {
			return expression_failure(checker, view, scope, node, .Mismatched_Types)
		}
		scalar = expression_conversion(
			checker,
			view,
			scope,
			scalar_node,
			expression_value_operand(checker, view, scalar_node, scalar),
			scalar,
			matrix_base.elem,
			.Assignment,
		) or_return
		if scalar.state == .Invalid { return expression_poison(scope), nil }
		scalar = check_expression(checker, view, scope, scalar_node, matrix_base.elem) or_return
		if scalar.state == .Invalid { return expression_poison(scope), nil }
	} else if types.resolve_named(store, scalar_info.type) != types.resolve_named(store, matrix_base.elem) {
		return expression_failure(checker, view, scope, node, .Mismatched_Types)
	} else if operator == .Mul && matrix_left {
		return expression_failure(checker, view, scope, node, .Mismatched_Types)
	} else if !comparison && operator != .Mul {
		return expression_failure(checker, view, scope, node, .Mismatched_Types)
	}
	result := matrix_info.type
	if comparison { result = checker.boolean }
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(
			Matrix_Binary_Plan {
				op = operator,
				left = Operand(Expression_Ref{view, binary.left}),
				right = Operand(Expression_Ref{view, binary.right}),
				result = result,
			},
		),
	) or_return
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "package")
expression_matrix_vector :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	base: Expression_Info,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	access := syntax.node_payload(file.ast, node, syntax.Index_Expr)
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, base.type))^
	vector_length := descriptor.count if !descriptor.row_major else descriptor.upper_bound
	vector_count := descriptor.upper_bound if !descriptor.row_major else descriptor.count
	position := check_expression(checker, view, scope, access.index, checker.default_integer) or_return
	if position.state == .Invalid { return expression_poison(scope), nil }
	statically_checked := false
	if position.mode == .Constant {
		integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
		index, index_error := big.int_get_i64(&integer)
		if index_error != nil || index < 0 || index >= vector_count {
			return expression_failure(checker, view, scope, access.index, .Invalid_Operand)
		}
		statically_checked = true
	}
	mode := Addressing_Mode.Variable if base.mode == .Variable else .Value
	vector_type := types.intern(store, types.Type{kind = .Array, elem = descriptor.elem, count = vector_length})
	policy := Check_Policy.Disabled if checker.unchecked_depth > 0 || statically_checked else Check_Policy.Enabled
	if checker.type_checker.files[file_id].policy.bounds_check == .Disabled { policy = .Disabled }
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Matrix_Vector_Plan{base = Operand(Expression_Ref{view, access.expr}), index = Operand(Expression_Ref{view, access.index}), policy = policy}),
	) or_return
	return Expression_Info{type = vector_type, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}
