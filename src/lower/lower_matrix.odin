package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

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

@(private)
matrix_storage_index :: proc(shape: types.Type, position: i64) -> i64 {
	if shape.row_major { return position }
	columns := shape.upper_bound
	return (position % columns) * shape.count + position / columns
}

@(private)
lower_matrix_element_address :: proc(state: ^Procedure_State, base: ir.Node_Id, shape: ^types.Type, row, column: i64, element_size: u32) -> ir.Node_Id {
	function := state.job.function
	storage: ir.Node_Id
	if shape.row_major {
		storage = ir.binary(
			function,
			.Add,
			ir.binary(function, .Mul, ir.const_int(function, .I64, row), ir.const_int(function, .I64, shape.upper_bound)),
			ir.const_int(function, .I64, column),
		)
	} else {
		storage = ir.binary(
			function,
			.Add,
			ir.binary(function, .Mul, ir.const_int(function, .I64, column), ir.const_int(function, .I64, shape.count)),
			ir.const_int(function, .I64, row),
		)
	}
	return ir.ptr_index(function, base, storage, element_size)
}

// One element operation on values: an address for complex elements, a scalar value otherwise.
@(private)
lower_matrix_element_op :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	left, right: ir.Node_Id,
	elem: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	#partial switch lower_type(state, elem).kind {
	case .Float:
		if is_float16(state, elem) {
			result, ok := lower_float16_operation(function, operator, left, right)
			if !ok { return lower_fail(state, node, .Operator) }
			return result
		}
		#partial switch operator {
		case .Add:
			return ir.binary(function, .FAdd, left, right)
		case .Sub:
			return ir.binary(function, .FSub, left, right)
		case .Mul:
			return ir.binary(function, .FMul, left, right)
		}
	case .Integer:
		#partial switch operator {
		case .Add:
			return ir.binary(function, .Add, left, right)
		case .Sub:
			return ir.binary(function, .Sub, left, right)
		case .Mul:
			return ir.binary(function, .Mul, left, right)
		case .And:
			return ir.binary(function, .And, left, right)
		case .Or:
			return ir.binary(function, .Or, left, right)
		case .Xor:
			return ir.binary(function, .Xor, left, right)
		case .And_Not:
			mask := ir.binary(function, .Xor, right, ir.const_int(function, function.nodes.type[right], -1))
			return ir.binary(function, .And, left, mask)
		}
	case .Complex:
		return lower_complex_binary(state, node, operator, left, right, elem)
	}
	return lower_fail(state, node, .Operator)
}

@(private)
lower_matrix_element_compare :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	left, right: ir.Node_Id,
	elem: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	#partial switch lower_type(state, elem).kind {
	case .Float:
		if is_float16(state, elem) {
			result, ok := lower_float16_operation(function, operator, left, right)
			if !ok { return lower_fail(state, node, .Operator) }
			return result
		}
		kind := ir.Node_Kind.FEq if operator == .Cmp_Eq else ir.Node_Kind.FNe
		return ir.compare(function, kind, left, right)
	case .Integer:
		kind := ir.Node_Kind.Eq if operator == .Cmp_Eq else ir.Node_Kind.Ne
		return ir.compare(function, kind, left, right)
	case .Complex:
		return lower_complex_binary(state, node, operator, left, right, elem)
	}
	return lower_fail(state, node, .Operator)
}

@(private)
lower_matrix_zero :: proc(state: ^Procedure_State, elem: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	#partial switch lower_type(state, elem).kind {
	case .Float:
		if is_float16(state, elem) { return ir.const_int(function, .I16, 0) }
		return ir.const_float(function, scalar_type(state, elem), 0)
	case .Integer:
		return ir.const_int(function, scalar_type(state, elem), 0)
	case .Complex:
		layout := state.job.layouts[elem]
		if layout.error != .None { return lower_fail(state, state.job.procedure.body.node, .Operator) }
		slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
		memory := ir.add_node(
			function,
			.Mem_Set,
			.Memory,
			{
				state.builder.control,
				ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
				slot,
				ir.const_int(function, .I8, 0),
				ir.const_int(function, .I64, layout.size),
			},
		)
		ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
		return slot
	}
	return lower_fail(state, state.job.procedure.body.node, .Operator)
}

// Reduction trees matching the official emission: square even products reduce pairwise with odd carry
// (`llvm_vector_mul_pairwise_reduce_add`), simdable non-square products use the shuffle reduction
// (`llvm_vector_reduce_add`), anything else sums k-ascending like the scalar `lb_emit_mul_add` loop.
// Integers are exact under any tree; floats select below.
Matrix_Reduction :: enum {
	Ascending,
	Pairwise,
	Shuffle,
}

@(private)
matrix_float_add :: proc(state: ^Procedure_State, node: syntax.Node_Index, left, right: ir.Node_Id, elem: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	if is_float16(state, elem) {
		result, ok := lower_float16_operation(function, .Add, left, right)
		if !ok { return lower_fail(state, node, .Operator) }
		return result
	}
	return ir.binary(function, .FAdd, left, right)
}

// The official simd gate (`lb_is_matrix_simdable`): native-endian 32/64-bit floats, 16-byte alignment,
// and at least one even dimension. Our only target is amd64, which the official gate allows.
@(private)
matrix_simd_gate :: proc(state: ^Procedure_State, matrix_type: types.Type_Id, shape: ^types.Type) -> bool {
	elem_base := lower_type(state, shape.elem)
	if elem_base.kind != .Float || is_float16(state, shape.elem) { return false }
	if elem_base.endianness == .Big { return false }
	if state.job.layouts[matrix_type].align < 16 { return false }
	if shape.count & 1 == 1 && shape.upper_bound & 1 == 1 { return false }
	return true
}

// Pairwise halving with the odd term carried, over the product buffer.
@(private)
matrix_reduce_pairwise :: proc(state: ^Procedure_State, node: syntax.Node_Index, products: []ir.Node_Id, elem: types.Type_Id) -> ir.Node_Id {
	count := len(products)
	if count == 1 { return products[0] }
	buffer: [64]ir.Node_Id
	for product, index in products { buffer[index] = product }
	remaining := count
	for remaining > 1 {
		half := remaining / 2
		for j in 0 ..< half { buffer[j] = matrix_float_add(state, node, buffer[2 * j], buffer[2 * j + 1], elem) }
		if remaining % 2 == 1 { buffer[half] = buffer[remaining - 1] }
		remaining = (remaining + 1) / 2
		if state.failed { return 0 }
	}
	return buffer[0]
}

// The official shuffle reduction: pow2 lengths halve the low against the high half, shorter lengths
// split at the previous pow2 with the upper part zero-padded to pow2, then add the two halves.
@(private)
matrix_reduce_shuffle_range :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	buffer: ^[64]ir.Node_Id,
	start, length: int,
	elem: types.Type_Id,
) -> ir.Node_Id {
	if length == 1 { return buffer[start] }
	power := 1
	for power * 2 <= length { power *= 2 }
	if power == length {
		stride := length
		for stride != 1 {
			stride /= 2
			for index in 0 ..< stride {
				buffer[start + index] = matrix_float_add(state, node, buffer[start + index], buffer[start + index + stride], elem)
			}
			if state.failed { return 0 }
		}
		return buffer[start]
	}
	lower := matrix_reduce_shuffle_range(state, node, buffer, start, power, elem)
	if state.failed { return 0 }
	padded: [64]ir.Node_Id
	upper_length := length - power
	expanded := 1
	for expanded < upper_length { expanded *= 2 }
	zero := lower_matrix_zero(state, elem)
	if state.failed { return 0 }
	for index in 0 ..< expanded {
		padded[index] = zero
		if index < upper_length { padded[index] = buffer[start + power + index] }
	}
	upper := matrix_reduce_shuffle_range(state, node, &padded, 0, expanded, elem)
	if state.failed { return 0 }
	return matrix_float_add(state, node, lower, upper, elem)
}

@(private)
matrix_reduce_shuffle :: proc(state: ^Procedure_State, node: syntax.Node_Index, products: []ir.Node_Id, elem: types.Type_Id) -> ir.Node_Id {
	buffer: [64]ir.Node_Id
	for product, index in products { buffer[index] = product }
	return matrix_reduce_shuffle_range(state, node, &buffer, 0, len(products), elem)
}

// Sums one element's products: pairwise or shuffle trees for simdable floats, k-ascending otherwise.
// The ascending loop adds each product onto the running sum, matching the official scalar loop.
@(private)
lower_matrix_sum :: proc(state: ^Procedure_State, node: syntax.Node_Index, products: []ir.Node_Id, tree: Matrix_Reduction, elem: types.Type_Id) -> ir.Node_Id {
	#partial switch tree {
	case .Pairwise:
		return matrix_reduce_pairwise(state, node, products, elem)
	case .Shuffle:
		return matrix_reduce_shuffle(state, node, products, elem)
	}
	function := state.job.function
	accumulator := lower_matrix_zero(state, elem)
	if state.failed { return 0 }
	for product in products {
		if lower_type(state, elem).kind == .Complex {
			accumulator = lower_complex_binary(state, node, .Add, accumulator, product, elem)
		} else if lower_type(state, elem).kind == .Float {
			accumulator = matrix_float_add(state, node, product, accumulator, elem)
		} else {
			accumulator = ir.binary(function, .Add, accumulator, product)
		}
		if state.failed || function.error != nil { return 0 }
	}
	return accumulator
}

// Each operand evaluates once. A scalar operand keeps its value: `*` broadcasts it while any other operator
// reads it on the diagonal and zero elsewhere, matching the official scaled-identity conversion.
@(private)
lower_matrix_binary :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Matrix_Binary_Plan) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	function := state.job.function
	left_kind := lower_type(state, operand_type(state, plan.left)).kind
	if state.failed { return 0 }
	right_kind := lower_type(state, operand_type(state, plan.right)).kind
	if state.failed { return 0 }
	left_aggregate := left_kind == .Matrix || left_kind == .Array
	right_aggregate := right_kind == .Matrix || right_kind == .Array
	matrix_shape := lower_type(state, operand_type(state, plan.left)) if left_kind == .Matrix else nil
	if right_kind == .Matrix { matrix_shape = lower_type(state, operand_type(state, plan.right)) }
	if state.failed { return 0 }
	if matrix_shape == nil || matrix_shape.kind != .Matrix { return lower_fail(state, node, .Operator) }
	elem := matrix_shape.elem
	element_layout := state.job.layouts[elem]
	if element_layout.error != .None || element_layout.size <= 0 || element_layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Operator)
	}
	element_size := u32(element_layout.size)
	left_value := lower_operand(state, plan.left, 0 if left_aggregate else elem)
	if state.failed || function.error != nil { return 0 }
	right_value := lower_operand(state, plan.right, 0 if right_aggregate else elem)
	if state.failed || function.error != nil { return 0 }
	layout := state.job.layouts[plan.result]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Operator) }
	if plan.op == .Cmp_Eq || plan.op == .Not_Eq {
		return lower_matrix_compare(state, node, plan, left_value, right_value, elem, element_size)
	}
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	if plan.op == .Mul && left_aggregate && right_aggregate {
		if left_kind == .Matrix && right_kind == .Matrix {
			return lower_matrix_product(state, node, plan, slot, left_value, right_value, elem, element_size)
		}
		return lower_matrix_vector_product(state, node, plan, slot, left_value, right_value, left_kind, elem, element_size)
	}
	return lower_matrix_elementwise(state, node, plan, slot, left_value, right_value, elem, element_size)
}

// The matrix product sums k-ascending with no FMA contraction.
@(private)
lower_matrix_product :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Matrix_Binary_Plan,
	slot, left_base, right_base: ir.Node_Id,
	elem: types.Type_Id,
	element_size: u32,
) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	left_shape := lower_type(state, operand_type(state, plan.left))
	right_shape := lower_type(state, operand_type(state, plan.right))
	result_shape := types.get(store, types.resolve_named(store, plan.result))
	rows := result_shape.count
	columns := result_shape.upper_bound
	steps := left_shape.upper_bound
	left_id := operand_type(state, plan.left)
	if state.failed { return 0 }
	tree := Matrix_Reduction.Ascending
	if matrix_simd_gate(state, left_id, left_shape) {
		if rows == columns && rows == steps && steps % 2 == 0 {
			tree = .Pairwise
		} else {
			tree = .Shuffle
		}
	}
	for row in 0 ..< rows {
		for column in 0 ..< columns {
			products: [64]ir.Node_Id
			for step in 0 ..< steps {
				first := lower_load(state, lower_matrix_element_address(state, left_base, left_shape, row, step, element_size), elem)
				second := lower_load(state, lower_matrix_element_address(state, right_base, right_shape, step, column, element_size), elem)
				products[step] = lower_matrix_element_op(state, node, .Mul, first, second, elem)
				if state.failed || function.error != nil { return 0 }
			}
			accumulator := lower_matrix_sum(state, node, products[:steps], tree, elem)
			if state.failed || function.error != nil { return 0 }
			lower_store(state, lower_matrix_element_address(state, slot, result_shape, row, column, element_size), accumulator, elem)
			if state.failed { return 0 }
		}
	}
	return slot
}

@(private)
lower_matrix_vector_product :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Matrix_Binary_Plan,
	slot, left_value, right_value: ir.Node_Id,
	left_kind: types.Kind,
	elem: types.Type_Id,
	element_size: u32,
) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	left_shape := lower_type(state, operand_type(state, plan.left))
	right_shape := lower_type(state, operand_type(state, plan.right))
	result_shape := types.get(store, types.resolve_named(store, plan.result))
	count := result_shape.count
	if result_shape.kind == .Matrix { count *= result_shape.upper_bound }
	matrix_left := left_kind == .Matrix
	matrix_shape := left_shape if matrix_left else right_shape
	steps := matrix_shape.upper_bound if matrix_left else matrix_shape.count
	matrix_id := operand_type(state, plan.left) if matrix_left else operand_type(state, plan.right)
	if state.failed { return 0 }
	tree := Matrix_Reduction.Ascending
	if !matrix_shape.row_major && matrix_simd_gate(state, matrix_id, matrix_shape) { tree = .Pairwise }
	for index in 0 ..< count {
		products: [64]ir.Node_Id
		for step in 0 ..< steps {
			first: ir.Node_Id
			second: ir.Node_Id
			if matrix_left {
				first = lower_load(state, lower_matrix_element_address(state, left_value, matrix_shape, index, step, element_size), elem)
				second = lower_load(state, ir.ptr_offset(function, right_value, step * i64(element_size)), elem)
			} else {
				first = lower_load(state, ir.ptr_offset(function, left_value, step * i64(element_size)), elem)
				second = lower_load(state, lower_matrix_element_address(state, right_value, matrix_shape, step, index, element_size), elem)
			}
			products[step] = lower_matrix_element_op(state, node, .Mul, first, second, elem)
			if state.failed || function.error != nil { return 0 }
		}
		accumulator := lower_matrix_sum(state, node, products[:steps], tree, elem)
		if state.failed || function.error != nil { return 0 }
		lower_store(state, ir.ptr_offset(function, slot, index * i64(element_size)), accumulator, elem)
		if state.failed { return 0 }
	}
	return slot
}

// A scalar reads on the diagonal and zero elsewhere for anything but `*`, which broadcasts it.
@(private)
lower_matrix_read_operand :: proc(
	state: ^Procedure_State,
	base: ir.Node_Id,
	shape: ^types.Type,
	row, column, position: i64,
	scalar, zero: ir.Node_Id,
	elem: types.Type_Id,
	element_size: u32,
	broadcast: bool,
) -> ir.Node_Id {
	if shape != nil {
		storage := position
		if shape.kind == .Matrix {
			storage = matrix_storage_index(shape^, position)
		}
		return lower_load(state, ir.ptr_offset(state.job.function, base, i64(storage) * i64(element_size)), elem)
	}
	if broadcast {
		return scalar
	}
	return scalar if row == column else zero
}

@(private)
lower_matrix_elementwise :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Matrix_Binary_Plan,
	slot, left_value, right_value: ir.Node_Id,
	elem: types.Type_Id,
	element_size: u32,
) -> ir.Node_Id {
	store := check.type_store(state.job.program)
	result_shape := types.get(store, types.resolve_named(store, plan.result))
	rows := result_shape.count
	columns := result_shape.upper_bound
	left_operand := lower_type(state, operand_type(state, plan.left))
	left_shape := left_operand if left_operand.kind == .Matrix || left_operand.kind == .Array else nil
	right_operand := lower_type(state, operand_type(state, plan.right))
	right_shape := right_operand if right_operand.kind == .Matrix || right_operand.kind == .Array else nil
	if state.failed { return 0 }
	zero := lower_matrix_zero(state, elem)
	if state.failed { return 0 }
	broadcast := plan.op == .Mul
	for row in 0 ..< rows {
		for column in 0 ..< columns {
			position := row * columns + column
			first := lower_matrix_read_operand(state, left_value, left_shape, row, column, position, left_value, zero, elem, element_size, broadcast)
			second := lower_matrix_read_operand(state, right_value, right_shape, row, column, position, right_value, zero, elem, element_size, broadcast)
			value := lower_matrix_element_op(state, node, plan.op, first, second, elem)
			if state.failed || state.job.function.error != nil { return 0 }
			destination := matrix_storage_index(result_shape^, position)
			lower_store(state, ir.ptr_offset(state.job.function, slot, destination * i64(element_size)), value, elem)
			if state.failed { return 0 }
		}
	}
	return slot
}

@(private)
lower_matrix_compare :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	plan: check.Matrix_Binary_Plan,
	left_value, right_value: ir.Node_Id,
	elem: types.Type_Id,
	element_size: u32,
) -> ir.Node_Id {
	function := state.job.function
	left_operand := lower_type(state, operand_type(state, plan.left))
	left_shape := left_operand if left_operand.kind == .Matrix || left_operand.kind == .Array else nil
	right_operand := lower_type(state, operand_type(state, plan.right))
	right_shape := right_operand if right_operand.kind == .Matrix || right_operand.kind == .Array else nil
	if state.failed { return 0 }
	matrix_shape := left_shape if left_shape != nil else right_shape
	count := matrix_shape.count * matrix_shape.upper_bound
	zero := lower_matrix_zero(state, elem)
	if state.failed { return 0 }
	accumulator := ir.const_int(function, .Bool, 1 if plan.op == .Cmp_Eq else 0)
	combine := ir.Node_Kind.And if plan.op == .Cmp_Eq else ir.Node_Kind.Or
	for position in 0 ..< count {
		row := position / matrix_shape.upper_bound
		column := position % matrix_shape.upper_bound
		first := lower_matrix_read_operand(state, left_value, left_shape, row, column, position, left_value, zero, elem, element_size, false)
		second := lower_matrix_read_operand(state, right_value, right_shape, row, column, position, right_value, zero, elem, element_size, false)
		compared := lower_matrix_element_compare(state, node, plan.op, first, second, elem)
		if state.failed || function.error != nil { return 0 }
		accumulator = ir.binary(function, combine, accumulator, compared)
	}
	return accumulator
}

@(private)
lower_matrix_unary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	operand_node: syntax.Node_Index,
	result: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	shape := types.get(store, types.resolve_named(store, result))
	elem := shape.elem
	element_layout := state.job.layouts[elem]
	if element_layout.error != .None || element_layout.size <= 0 || element_layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Operator)
	}
	element_size := u32(element_layout.size)
	base := lower_array_base(state, operand_node)
	if state.failed || function.error != nil { return 0 }
	layout := state.job.layouts[result]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Operator) }
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	count := shape.count * shape.upper_bound
	for position in 0 ..< count {
		storage := matrix_storage_index(shape^, position)
		address := ir.ptr_offset(function, base, i64(storage) * i64(element_size))
		destination := ir.ptr_offset(function, slot, i64(storage) * i64(element_size))
		if operator == .Add {
			lower_store(state, destination, lower_load(state, address, elem), elem)
		} else if lower_type(state, elem).kind == .Complex {
			lower_store(state, destination, lower_complex_unary(state, node, operator, address, elem), elem)
		} else {
			value := lower_load(state, address, elem)
			#partial switch operator {
			case .Sub:
				if is_float16(state, elem) {
					zero := lower_matrix_zero(state, elem)
					if state.failed { return 0 }
					negated, ok := lower_float16_operation(function, .Sub, zero, value)
					if !ok { return lower_fail(state, node, .Operator) }
					value = negated
				} else if lower_type(state, elem).kind == .Float {
					value = ir.unary(function, .FNeg, value)
				} else {
					value = ir.binary(function, .Sub, ir.const_int(function, function.nodes.type[value], 0), value)
				}
			case .Xor:
				value = ir.binary(function, .Xor, value, ir.const_int(function, function.nodes.type[value], -1))
			case:
				return lower_fail(state, node, .Operator)
			}
			lower_store(state, destination, value, elem)
		}
		if state.failed { return 0 }
	}
	return slot
}

// Scaled identity from a scalar assignment: the scalar lands on the diagonal, zero elsewhere. The source lowers
// once before this call, so the stored diagonal value is reused without re-evaluation.
@(private)
lower_matrix_scalar_init :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	shape := lower_type(state, type)
	if state.failed { return 0 }
	layout := state.job.layouts[type]
	if layout.error != .None || shape.kind != .Matrix || shape.count != shape.upper_bound || layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Conversion)
	}
	element_size := u32(state.job.layouts[shape.elem].size)
	if state.job.layouts[shape.elem].error != .None || element_size == 0 {
		return lower_fail(state, node, .Conversion)
	}
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	zero := lower_matrix_zero(state, shape.elem)
	if state.failed { return 0 }
	for row in 0 ..< shape.count {
		for column in 0 ..< shape.count {
			position := row * shape.count + column
			destination := ir.ptr_offset(function, slot, i64(matrix_storage_index(shape^, position)) * i64(element_size))
			if row == column {
				lower_store(state, destination, value, shape.elem)
			} else {
				lower_store(state, destination, zero, shape.elem)
			}
		}
		if state.failed { return 0 }
	}
	return slot
}

// Element-wise product for `hadamard_product`: matrix pairs reuse the operator path, array pairs use a flat loop.
// A matrix cast keeps each (row, column) element for identical shapes, copies the overlapping
// top-left elements with diagonal ones for square destinations, and reorders column-major
// elements for reshapes, converting each element like a scalar cast.
@(private)
lower_matrix_cast :: proc(state: ^Procedure_State, node: syntax.Node_Index, source, target: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	source_shape := lower_type(state, source)
	target_shape := lower_type(state, target)
	if state.failed { return 0 }
	if source_shape.kind != .Matrix || target_shape.kind != .Matrix { return lower_fail(state, node, .Conversion) }
	source_layout := state.job.layouts[source_shape.elem]
	target_layout := state.job.layouts[target]
	element_layout := state.job.layouts[target_shape.elem]
	if source_layout.error != .None || target_layout.error != .None || element_layout.error != .None {
		return lower_fail(state, node, .Conversion)
	}
	if source_layout.size <= 0 ||
	   source_layout.size > i64(max(u32)) ||
	   element_layout.size <= 0 ||
	   element_layout.size > i64(max(u32)) ||
	   target_layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Conversion)
	}
	source_size := u32(source_layout.size)
	element_size := u32(element_layout.size)
	slot := ir.stack_slot(function, state.entry_control, u32(max(target_layout.size, 1)), u32(target_layout.align))
	lower_memory_effect(state, .Mem_Set, slot, ir.const_int(function, .I8, 0), ir.const_int(function, .I64, target_layout.size))
	if state.failed { return 0 }
	rows, columns := target_shape.count, target_shape.upper_bound
	if (source_shape.count == rows && source_shape.upper_bound == columns) || rows == columns {
		one: ir.Node_Id
		if rows == columns && (source_shape.count != rows || source_shape.upper_bound != columns) {
			one = lower_matrix_one(state, target_shape.elem)
			if state.failed { return 0 }
		}
		for row in 0 ..< rows {
			for column in 0 ..< columns {
				if row < source_shape.count && column < source_shape.upper_bound {
					element := lower_load(state, lower_matrix_element_address(state, value, source_shape, row, column, source_size), source_shape.elem)
					converted := lower_matrix_cast_element(state, node, element, source_shape.elem, target_shape.elem)
					lower_store(state, lower_matrix_element_address(state, slot, target_shape, row, column, element_size), converted, target_shape.elem)
				} else if rows == columns && row == column {
					lower_store(state, lower_matrix_element_address(state, slot, target_shape, row, column, element_size), one, target_shape.elem)
				}
			}
			if state.failed || function.error != nil { return 0 }
		}
		return slot
	}
	if types.resolve_named(store, source_shape.elem) == types.resolve_named(store, target_shape.elem) && state.job.layouts[source].size == target_layout.size {
		lower_memory_effect(state, .Mem_Copy, slot, value, ir.const_int(function, .I64, target_layout.size))
		return slot
	}
	count := source_shape.count * source_shape.upper_bound
	for index in 0 ..< count {
		element := lower_load(
			state,
			lower_matrix_element_address(state, value, source_shape, index % source_shape.count, index / source_shape.count, source_size),
			source_shape.elem,
		)
		converted := lower_matrix_cast_element(state, node, element, source_shape.elem, target_shape.elem)
		lower_store(state, lower_matrix_element_address(state, slot, target_shape, index % rows, index / rows, element_size), converted, target_shape.elem)
		if state.failed || function.error != nil { return 0 }
	}
	return slot
}

// Each element converts like a scalar cast; a real element becomes complex with a zero imaginary part.
@(private)
lower_matrix_cast_element :: proc(state: ^Procedure_State, node: syntax.Node_Index, value: ir.Node_Id, source, target: types.Type_Id) -> ir.Node_Id {
	if source == target { return value }
	if lower_complex_kind(state, source) && lower_complex_kind(state, target) {
		return lower_complex_conversion(state, node, value, source, target)
	}
	if lower_type(state, target).kind == .Complex {
		return lower_matrix_real_to_complex(state, node, value, source, target)
	}
	plan := check.Conversion_Plan {
		kind   = .Cast,
		target = target,
	}
	return lower_conversion_value(state, plan, node, source, value)
}

@(private)
lower_matrix_real_to_complex :: proc(state: ^Procedure_State, node: syntax.Node_Index, value: ir.Node_Id, source, target: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	layout := state.job.layouts[target]
	if layout.error != .None || layout.size % 2 != 0 { return lower_fail(state, node, .Conversion) }
	component_size := layout.size / 2
	scalar := component_scalar(component_size)
	if scalar != .F32 && scalar != .F64 { return lower_fail(state, node, .Conversion) }
	source_scalar := scalar_type(state, source)
	if source_scalar == .None { return lower_fail(state, node, .Conversion) }
	real := value
	if source_scalar == .F16 {
		real = float16_widen(function, real)
		source_scalar = .F32
	}
	if source_scalar != scalar {
		if source_scalar == .F32 && scalar == .F64 {
			real = ir.convert(function, .Float_Ext, real, .F64)
		} else if source_scalar == .F64 && scalar == .F32 {
			real = ir.convert(function, .Float_Trunc, real, .F32)
		} else {
			return lower_fail(state, node, .Conversion)
		}
	}
	slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	lower_store_word(state, slot, real)
	lower_store_word(state, ir.ptr_offset(function, slot, component_size), ir.const_float(function, scalar, 0))
	return slot
}

// The diagonal fill for a larger square destination: one converted to the element type.
@(private)
lower_matrix_one :: proc(state: ^Procedure_State, elem: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	#partial switch lower_type(state, elem).kind {
	case .Float:
		if is_float16(state, elem) { return ir.const_int(function, .I16, i64(transmute(u16)f16(1))) }
		scalar := scalar_type(state, elem)
		if scalar == .F32 { return ir.const_float(function, scalar, u64(transmute(u32)f32(1))) }
		if scalar == .F64 { return ir.const_float(function, scalar, transmute(u64)f64(1)) }
	case .Integer:
		scalar := scalar_type(state, elem)
		if scalar >= .I8 && scalar <= .I64 { return ir.const_int(function, scalar, 1) }
	case .Complex:
		layout := state.job.layouts[elem]
		if layout.error == .None && layout.size % 2 == 0 {
			component_size := layout.size / 2
			scalar := component_scalar(component_size)
			if scalar == .F32 || scalar == .F64 {
				slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
				one := ir.const_float(function, scalar, u64(transmute(u32)f32(1)) if scalar == .F32 else transmute(u64)f64(1))
				lower_store_word(state, slot, one)
				lower_store_word(state, ir.ptr_offset(function, slot, component_size), ir.const_float(function, scalar, 0))
				return slot
			}
		}
	}
	return lower_fail(state, state.job.procedure.body.node, .Conversion)
}
@(private)
lower_matrix_hadamard :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	type: types.Type_Id,
	left_operand, right_operand: check.Operand,
	left_value, right_value: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	shape := lower_type(state, type)
	if state.failed { return 0 }
	layout := state.job.layouts[type]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
	element_layout := state.job.layouts[shape.elem]
	if element_layout.error != .None || element_layout.size <= 0 || element_layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Builtin)
	}
	element_size := u32(element_layout.size)
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	if shape.kind == .Matrix {
		plan := check.Matrix_Binary_Plan {
			op     = .Mul,
			left   = left_operand,
			right  = right_operand,
			result = type,
		}
		return lower_matrix_elementwise(state, node, plan, slot, left_value, right_value, shape.elem, element_size)
	}
	if shape.kind != .Array { return lower_fail(state, node, .Builtin) }
	for index in 0 ..< shape.count {
		first := lower_load(state, ir.ptr_offset(function, left_value, i64(index) * i64(element_size)), shape.elem)
		second := lower_load(state, ir.ptr_offset(function, right_value, i64(index) * i64(element_size)), shape.elem)
		value := lower_matrix_element_op(state, node, .Mul, first, second, shape.elem)
		if state.failed || function.error != nil { return 0 }
		lower_store(state, ir.ptr_offset(function, slot, i64(index) * i64(element_size)), value, shape.elem)
		if state.failed { return 0 }
	}
	return slot
}

// `matrix_flatten` copies the physical storage bytes into a fresh array slot; the result is independent.
@(private)
lower_matrix_flatten :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	layout := state.job.layouts[type]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	lower_memory_effect(state, .Mem_Copy, slot, value, ir.const_int(function, .I64, layout.size))
	return slot
}

// `outer_product` fills `result[i, j]` with `left[i] * right[j]`.
@(private)
lower_matrix_outer :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id, left_value, right_value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	shape := lower_type(state, type)
	if state.failed { return 0 }
	layout := state.job.layouts[type]
	if layout.error != .None || shape.kind != .Matrix || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
	element_layout := state.job.layouts[shape.elem]
	if element_layout.error != .None || element_layout.size <= 0 || element_layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Builtin)
	}
	element_size := u32(element_layout.size)
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	for row in 0 ..< shape.count {
		for column in 0 ..< shape.upper_bound {
			first := lower_load(state, ir.ptr_offset(function, left_value, row * i64(element_size)), shape.elem)
			second := lower_load(state, ir.ptr_offset(function, right_value, column * i64(element_size)), shape.elem)
			value := lower_matrix_element_op(state, node, .Mul, first, second, shape.elem)
			if state.failed || function.error != nil { return 0 }
			lower_store(state, lower_matrix_element_address(state, slot, shape, row, column, element_size), value, shape.elem)
			if state.failed { return 0 }
		}
	}
	return slot
}

// `transpose` fills `result[i, j]` with `source[j, i]`.
@(private)
lower_matrix_transpose :: proc(state: ^Procedure_State, node: syntax.Node_Index, type, source_type: types.Type_Id, source_value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	shape := lower_type(state, type)
	source := lower_type(state, source_type)
	if state.failed { return 0 }
	layout := state.job.layouts[type]
	if layout.error != .None || shape.kind != .Matrix || source.kind != .Matrix || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
	element_layout := state.job.layouts[shape.elem]
	if element_layout.error != .None || element_layout.size <= 0 || element_layout.size > i64(max(u32)) {
		return lower_fail(state, node, .Builtin)
	}
	element_size := u32(element_layout.size)
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	for row in 0 ..< shape.count {
		for column in 0 ..< shape.upper_bound {
			value := lower_load(state, lower_matrix_element_address(state, source_value, source, column, row, element_size), shape.elem)
			if state.failed || function.error != nil { return 0 }
			lower_store(state, lower_matrix_element_address(state, slot, shape, row, column, element_size), value, shape.elem)
			if state.failed { return 0 }
		}
	}
	return slot
}
