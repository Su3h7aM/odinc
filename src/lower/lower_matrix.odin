package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// A matrix element lives at its storage index: column-major storage holds columns, row-major storage holds rows.
// Constant indices are checked by the checker; runtime indices trap when out of range, like array indexing.
@(private)
lower_matrix_index_address :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Matrix_Index_Plan) -> ir.Node_Id {
	base, is_expression := plan.base.(check.Expression_Ref)
	if !is_expression || base.view != state.view { return lower_fail(state, node, .Place) }
	shape := lower_type(state, lower_info(state, base.node).type)
	if shape.kind != .Matrix { return lower_fail(state, node, .Place) }
	element := state.job.layouts[shape.elem]
	if element.error != .None { return lower_fail(state, node, .Place) }
	function := state.job.function
	row := lower_bound(state, plan.row, ir.const_int(function, .I64, 0))
	if state.failed || function.error != nil { return 0 }
	column := lower_bound(state, plan.column, ir.const_int(function, .I64, 0))
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[row] != .I64 || function.nodes.type[column] != .I64 { return lower_fail(state, node, .Bounds) }
	if plan.policy == .Enabled {
		lower_check(state, ir.compare(function, .ULt, row, ir.const_int(function, .I64, shape.count)))
		lower_check(state, ir.compare(function, .ULt, column, ir.const_int(function, .I64, shape.upper_bound)))
	}
	storage: ir.Node_Id
	if shape.row_major {
		storage = ir.binary(function, .Add, ir.binary(function, .Mul, row, ir.const_int(function, .I64, shape.upper_bound)), column)
	} else {
		storage = ir.binary(function, .Add, ir.binary(function, .Mul, column, ir.const_int(function, .I64, shape.count)), row)
	}
	address := lower_array_base(state, base.node)
	if state.failed || function.error != nil { return 0 }
	assert(element.size <= i64(max(u32)))
	return ir.ptr_index(function, address, storage, u32(element.size))
}

// A storage vector starts at its index times the vector length. Runtime indices trap when out of range.
@(private)
lower_matrix_vector_address :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Matrix_Vector_Plan) -> ir.Node_Id {
	base, is_expression := plan.base.(check.Expression_Ref)
	if !is_expression || base.view != state.view { return lower_fail(state, node, .Place) }
	shape := lower_type(state, lower_info(state, base.node).type)
	if shape.kind != .Matrix { return lower_fail(state, node, .Place) }
	element := state.job.layouts[shape.elem]
	if element.error != .None { return lower_fail(state, node, .Place) }
	function := state.job.function
	index := lower_bound(state, plan.index, ir.const_int(function, .I64, 0))
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[index] != .I64 { return lower_fail(state, node, .Bounds) }
	vector_count := shape.upper_bound if !shape.row_major else shape.count
	if plan.policy == .Enabled {
		lower_check(state, ir.compare(function, .ULt, index, ir.const_int(function, .I64, vector_count)))
	}
	vector_length := shape.count if !shape.row_major else shape.upper_bound
	stride := vector_length * element.size
	assert(stride <= i64(max(u32)))
	address := lower_array_base(state, base.node)
	if state.failed || function.error != nil { return 0 }
	return ir.ptr_index(function, address, index, u32(stride))
}
