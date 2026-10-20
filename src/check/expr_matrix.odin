package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

// `m[row, column]` selects one element. Only constant indices are supported so far: a runtime index needs a
// bounds plan for two axes, which is a later stage (docs/design/matrix.md, section 9).
Matrix_Index_Plan :: struct {
	base:   Operand,
	row:    i64,
	column: i64,
}

// Storage index of the element at `position` in row-major reading order, as matrix literals are written.
@(private = "package")
matrix_storage_index :: proc(descriptor: types.Type, position: int) -> int {
	if descriptor.row_major { return position }
	columns := int(descriptor.upper_bound)
	return (position % columns) * int(descriptor.count) + position / columns
}

// Returns the constant value of one index. Non-constant indices are not lowered yet and fail explicitly.
@(private = "file")
matrix_index_value :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	index_node: syntax.Node_Index,
	length: i64,
) -> (
	value: i64,
	info: Expression_Info,
	failed: bool,
	err: Resolve_Error,
) {
	position := check_expression(checker, view, scope, index_node, checker.default_integer) or_return
	if position.state == .Invalid { return 0, expression_poison(scope), true, nil }
	if position.mode != .Constant {
		info = expression_unsupported(checker, view, scope, index_node, "Matrix_Index_Runtime") or_return
		return 0, info, true, nil
	}
	integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
	index, index_error := big.int_get_i64(&integer)
	if index_error != nil || index < 0 || index >= length {
		info = expression_failure(checker, view, scope, index_node, .Invalid_Operand) or_return
		return 0, info, true, nil
	}
	return index, {}, false, nil
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
	row, row_info, row_failed := matrix_index_value(checker, view, scope, access.row_index, descriptor.count) or_return
	if row_failed { return row_info, nil }
	column, column_info, column_failed := matrix_index_value(checker, view, scope, access.column_index, descriptor.upper_bound) or_return
	if column_failed { return column_info, nil }
	mode := Addressing_Mode.Variable if base.mode == .Variable else .Value
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Matrix_Index_Plan{base = Operand(Expression_Ref{view, access.expr}), row = row, column = column})) or_return
	return Expression_Info{type = descriptor.elem, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}
