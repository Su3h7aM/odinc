package check

import "oc:syntax"
import "oc:types"

// Element count limit of matrix types, as MATRIX_ELEMENT_COUNT_MAX in the official compiler.
MATRIX_ELEMENT_COUNT_MAX :: 64

// Integers, floats and complex numbers may be matrix elements, with any endianness.
matrix_element_valid :: proc(store: ^types.Store, elem: types.Type_Id) -> bool {
	#partial switch types.get(store, types.resolve_named(store, elem)).kind {
	case .Integer, .Float, .Complex:
		return true
	}
	return false
}

// `#row_major` selects row-major storage; `#column_major` and no tag select column-major.
@(private = "file")
matrix_row_major :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	tag := syntax.node_payload(file.ast, node, syntax.Matrix_Type).tag
	return tag != 0 && expression_text(file, tag) == "#row_major"
}

// The `matrix[R, C]E` type expression.
matrix_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	shape := syntax.node_payload(file.ast, node, syntax.Matrix_Type)
	rows, rows_valid := array_count(checker, file_id, scope, shape.row_count) or_return
	columns, columns_valid := array_count(checker, file_id, scope, shape.column_count) or_return
	elem := type_expression(checker, file_id, scope, shape.elem, true) or_return
	if !rows_valid || !columns_valid || elem == types.TYPE_POISON { return types.TYPE_POISON, nil }
	if rows < 1 || columns < 1 || rows > MATRIX_ELEMENT_COUNT_MAX || columns > MATRIX_ELEMENT_COUNT_MAX || rows * columns > MATRIX_ELEMENT_COUNT_MAX {
		type_report(checker, file_id, file, node, .Invalid_Matrix_Count) or_return
		return types.TYPE_POISON, nil
	}
	if !matrix_element_valid(checker.store, elem) {
		type_report(checker, file_id, file, shape.elem, .Invalid_Matrix_Element) or_return
		return types.TYPE_POISON, nil
	}
	return types.intern(checker.store, types.Type{kind = .Matrix, elem = elem, count = rows, upper_bound = columns, row_major = matrix_row_major(file, node)}),
		nil
}
