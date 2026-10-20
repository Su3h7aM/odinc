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

// A single index selects the storage vector as an array: a column of length R, or a row of length C.
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
