package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_binary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	expression: syntax.Binary_Expr,
	conversions := check.Binary_Conversion_Plan{},
) -> ir.Node_Id {
	if expression.op.kind == .In || expression.op.kind == .Not_In {
		right_info := lower_info(state, expression.right)
		if lower_type(state, right_info.type).kind == .Map {
			lookup := check.Map_Index_Plan {
				map_value = check.Operand(check.Expression_Ref{state.view, expression.right}),
				key       = check.Operand(check.Expression_Ref{state.view, expression.left}),
			}
			_, found := lower_map_index(state, node, lookup)
			if state.failed { return 0 }
			return bool_not(state.job.function, found) if expression.op.kind == .Not_In else found
		}
	}
	// Array operands lower through the element-wise path, which evaluates each side once itself: eager
	// lowering here would choke on the Broadcast plans the checker puts on scalar operands.
	left_type := lower_operand_type(state, expression.left)
	if state.failed { return 0 }
	right_type := lower_operand_type(state, expression.right)
	if state.failed { return 0 }
	left_kind := lower_type(state, left_type).kind
	if state.failed { return 0 }
	right_kind := lower_type(state, right_type).kind
	if state.failed { return 0 }
	if left_kind == .Array || left_kind == .Enumerated_Array || right_kind == .Array || right_kind == .Enumerated_Array {
		return lower_array_binary(state, node, expression, conversions)
	}
	left: ir.Node_Id
	if conversions.left != 0 { left = lower_declared_conversion(state, expression.left, conversions.left) } else { left = lower_value(state, expression.left) }
	if state.failed { return 0 }
	if expression.op.kind == .Cmp_And || expression.op.kind == .Cmp_Or {
		return lower_short_circuit(state, expression.op.kind, expression.right, left)
	}
	right: ir.Node_Id
	if conversions.right !=
	   0 { right = lower_declared_conversion(state, expression.right, conversions.right) } else { right = lower_value(state, expression.right) }
	if state.failed { return 0 }
	if expression.op.kind == .In || expression.op.kind == .Not_In {
		found := lower_bit_set_membership(state, node, expression, left, right)
		if state.failed { return 0 }
		if expression.op.kind == .Not_In { return bool_not(state.job.function, found) }
		return found
	}
	if lower_type(state, left_type).kind == .Matrix || lower_type(state, right_type).kind == .Matrix {
		info := lower_info(state, node)
		if info.plan == 0 { return lower_fail(state, node, .Operator) }
		plan, is_matrix := check.plan(state.job.program, info.plan)^.(check.Matrix_Binary_Plan)
		if !is_matrix { return lower_fail(state, node, .Operator) }
		return lower_matrix_binary(state, node, plan)
	}
	simd_operator := check.Builtin_Kind.None
	#partial switch expression.op.kind {
	case .And:
		simd_operator = .Simd_Bit_And
	case .Or:
		simd_operator = .Simd_Bit_Or
	case .Xor:
		simd_operator = .Simd_Bit_Xor
	case .And_Not:
		simd_operator = .Simd_Bit_And_Not
	case .Add:
		simd_operator = .Simd_Add
	case .Sub:
		simd_operator = .Simd_Sub
	case .Mul:
		simd_operator = .Simd_Mul
	case .Quo:
		if lower_type(state, lower_info(state, node).type).kind == .Simd_Vector {
			elem, _ := simd_shape(state, lower_info(state, node).type)
			if scalar_type(state, elem) == .F32 || scalar_type(state, elem) == .F64 { simd_operator = .Simd_Div }
		}
	}
	if simd_operator != .None {
		operand_type := lower_info(state, node).type
		if lower_type(state, operand_type).kind == .Simd_Vector {
			values := [5]ir.Node_Id{left, right, 0, 0, 0}
			return lower_simd_lanewise(state, operand_type, simd_operator, values)
		}
	}
	if conversions.type != 0 && is_wide_integer(state, conversions.type) {
		return lower_wide_operator(state, node, expression.op.kind, signed_type(state, conversions.type), false, left, right)
	}
	if is_wide_integer(state, left_type) { return lower_wide_binary(state, node, expression, left, right) }
	if (expression.op.kind == .Shl || expression.op.kind == .Shr) && is_wide_integer(state, right_type) {
		right = wide_count_word(state, right, signed_type(state, right_type))
		if state.failed { return 0 }
	}
	if lower_operand_is_bit_set(state, expression.left) { return lower_bit_set_operator(state, node, expression.op.kind, left, right) }
	if lower_complex_kind(state, left_type) || lower_complex_kind(state, right_type) {
		if !lower_complex_kind(state, left_type) || !lower_complex_kind(state, right_type) { return lower_fail(state, node, .Operator) }
		return lower_complex_binary(state, node, expression.op.kind, left, right, left_type)
	}
	if is_nil_comparison(state, expression) { return lower_nil_comparison(state, expression, left, right) }
	if (expression.op.kind == .Cmp_Eq || expression.op.kind == .Not_Eq) &&
	   (lower_union_type(state, expression.left) != types.TYPE_NONE || lower_union_type(state, expression.right) != types.TYPE_NONE) {
		return lower_union_comparison(state, node, expression, conversions.type, left, right)
	}
	if (expression.op.kind == .Cmp_Eq || expression.op.kind == .Not_Eq) {
		if struct_type := lower_struct_compare_type(state, expression.left, expression.right); struct_type != types.TYPE_NONE {
			return lower_array_generated_equal(state, node, expression.op.kind, struct_type, left, right)
		}
	}
	operand_type := left_type
	if conversions.type != 0 { operand_type = conversions.type }
	return lower_scalar_binary(state, node, expression.op.kind, left, right, operand_type)
}

// The type an operand contributes to an operator. A type used where a value is expected is its typeid,
// matching the official backend, which lowers every Addressing_Type expression to lb_typeid.
@(private)
lower_operand_type :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> types.Type_Id {
	info := lower_info(state, node)
	if info.mode != .Type { return info.type }
	return types.intern(check.type_store(state.job.program), types.Type{kind = .Type_Id})
}

// One scalar operator: the shared tail of binary lowering, reused for every array lane.
@(private)
lower_scalar_binary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	left, right: ir.Node_Id,
	operand_type: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	type := function.nodes.type[left]
	signed := signed_type(state, operand_type)
	if scalar_type(state, operand_type) == .None { return lower_fail(state, node, .Operator) }
	floating := type == .F32 || type == .F64
	if is_float16(state, operand_type) {
		result, ok := lower_float16_operation(function, operator, left, right)
		if !ok { return lower_fail(state, node, .Operator) }
		return result
	}
	if type == .V128 { return lower_fail(state, node, .Operator) }
	#partial switch operator {
	case .Add:
		return ir.binary(function, .FAdd if floating else .Add, left, right)
	case .Sub:
		return ir.binary(function, .FSub if floating else .Sub, left, right)
	case .Mul:
		return ir.binary(function, .FMul if floating else .Mul, left, right)
	case .And:
		return ir.binary(function, .And, left, right)
	case .Or:
		return ir.binary(function, .Or, left, right)
	case .Xor:
		return ir.binary(function, .Xor, left, right)
	case .And_Not:
		return ir.binary(function, .And, left, ir.binary(function, .Xor, right, ir.const_int(function, type, -1)))
	case .Shl:
		return ir.binary(function, .Shl, left, right)
	case .Shr:
		return ir.binary(function, .Sar if signed else .Shr, left, right)
	case .Quo:
		if floating { return ir.binary(function, .FDiv, left, right) }
		return lower_integer_division(state, node, operator, signed, left, right)
	case .Mod, .Mod_Mod:
		if floating { return lower_fail(state, node, .Operator) }
		return lower_integer_division(state, node, operator, signed, left, right)
	case .Cmp_Eq:
		return ir.compare(function, .FEq if floating else .Eq, left, right)
	case .Not_Eq:
		return ir.compare(function, .FNe if floating else .Ne, left, right)
	case .Lt, .Gt:
		kind := ir.Node_Kind.FLt if floating else (ir.Node_Kind.SLt if signed else ir.Node_Kind.ULt)
		first, second := left, right
		if operator == .Gt { first, second = second, first }
		return lower_ordered_compare(function, kind, type, first, second)
	case .Lt_Eq, .Gt_Eq:
		kind := ir.Node_Kind.FLe if floating else (ir.Node_Kind.SLe if signed else ir.Node_Kind.ULe)
		first, second := left, right
		if operator == .Gt_Eq { first, second = second, first }
		return lower_ordered_compare(function, kind, type, first, second)
	}
	return lower_fail(state, node, .Operator)
}

// Pointers compare as addresses: the verifier only orders integers, so bit-cast to `u64` first, matching the official address comparison.
@(private)
lower_ordered_compare :: proc(function: ^ir.Function, kind: ir.Node_Kind, type: ir.Value_Type, first, second: ir.Node_Id) -> ir.Node_Id {
	if type == .Ptr {
		return ir.compare(function, kind, ir.convert(function, .Bitcast, first, .I64), ir.convert(function, .Bitcast, second, .I64))
	}
	return ir.compare(function, kind, first, second)
}

// One side of an array operator: an aggregate address, or a broadcast scalar reused for every lane.
Array_Factor :: struct {
	base:   ir.Node_Id,
	scalar: bool,
}

// Element-wise arithmetic over fixed arrays. Each operand lowers once, every lane combines through its
// scalar operator, and the result collects in a fresh slot, like compound assignment and simd lanes.
// A comparison reduces to a single boolean instead, matching the official reduction.
@(private)
lower_array_binary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	expression: syntax.Binary_Expr,
	conversions: check.Binary_Conversion_Plan,
) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	operator := expression.op.kind
	left_type := lower_info(state, expression.left).type
	if state.failed { return 0 }
	right_type := lower_info(state, expression.right).type
	if state.failed { return 0 }
	array_type := left_type
	array_kind := lower_type(state, left_type).kind
	if state.failed { return 0 }
	if array_kind != .Array && array_kind != .Enumerated_Array {
		array_type = right_type
		array_kind = lower_type(state, right_type).kind
		if state.failed { return 0 }
	}
	if array_kind != .Array && array_kind != .Enumerated_Array { return lower_fail(state, node, .Operator) }
	array_shape := lower_type(state, array_type)
	if state.failed { return 0 }
	left := lower_array_factor(state, expression.left, conversions.left, array_shape.elem)
	if state.failed { return 0 }
	right := lower_array_factor(state, expression.right, conversions.right, array_shape.elem)
	if state.failed { return 0 }
	if operator == .Cmp_Eq || operator == .Not_Eq {
		return lower_array_compare(state, node, operator, array_type, left, right)
	}
	result := lower_info(state, node).type
	if state.failed { return 0 }
	if lower_type(state, result).kind != .Array && lower_type(state, result).kind != .Enumerated_Array {
		return lower_fail(state, node, .Operator)
	}
	layout := state.job.layouts[result]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Operator) }
	slot := ir.stack_slot(state.job.function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	lower_array_fill(state, node, operator, result, slot, left, right)
	if state.failed { return 0 }
	return slot
}

// An array operand lowers to its base address; a broadcast scalar lowers to its element value.
@(private)
lower_array_factor :: proc(state: ^Procedure_State, node: syntax.Node_Index, declared: check.Plan_Id, elem: types.Type_Id) -> Array_Factor {
	if state.failed { return {} }
	if declared != 0 {
		return {base = lower_declared_conversion(state, node, declared)}
	}
	info := lower_info(state, node)
	if state.failed { return {} }
	// A Broadcast plan splats its scalar source into every lane, even though the operand already carries the array type.
	if info.plan != 0 {
		plan := check.plan(state.job.program, info.plan)
		if plan == nil { lower_fail(state, node, .Operator); return {} }
		if conversion, is_conversion := plan^.(check.Conversion_Plan); is_conversion && conversion.kind == .Broadcast {
			return {base = lower_array_broadcast(state, node, info, elem), scalar = true}
		}
	}
	kind := lower_type(state, info.type).kind
	if state.failed { return {} }
	if kind != .Array && kind != .Enumerated_Array {
		return {base = lower_array_broadcast(state, node, info, elem), scalar = true}
	}
	// An aggregate value already lives in memory, so the address lower_value returns is the base.
	return {base = lower_value(state, node)}
}

// A broadcast scalar splats into every lane. Typed scalars carry a Broadcast plan from checking;
// untyped ones convert to the element type directly. Into nested arrays the scalar converts to the
// innermost element and rides the scalar flag down.
@(private)
lower_array_broadcast :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, elem: types.Type_Id) -> ir.Node_Id {
	if state.failed { return 0 }
	leaf := elem
	for {
		unwrapped := types.get(check.type_store(state.job.program), types.resolve_named(check.type_store(state.job.program), leaf))
		if unwrapped.kind != .Array && unwrapped.kind != .Enumerated_Array { break }
		leaf = unwrapped.elem
	}
	if state.failed { return 0 }
	if info.plan != 0 {
		plan := check.plan(state.job.program, info.plan)
		if plan == nil { return lower_fail(state, node, .Operator) }
		if conversion, is_conversion := plan^.(check.Conversion_Plan); is_conversion && conversion.kind == .Broadcast {
			if lower_type(state, leaf).kind == .Complex || lower_type(state, leaf).kind == .Quaternion {
				return lower_array_complex_splat(state, node, conversion, leaf)
			}
			adjusted := conversion
			adjusted.target = leaf
			return lower_conversion(state, adjusted, node)
		}
	}
	value := lower_operand(state, check.Expression_Ref{state.view, node}, leaf)
	if state.failed || state.job.function.error != nil { return 0 }
	if state.job.function.nodes.type[value] == scalar_type(state, leaf) { return value }
	conversion := check.Conversion_Plan {
		kind   = .Assignment,
		source = check.Expression_Ref{state.view, node},
		target = leaf,
	}
	return lower_conversion_value(state, conversion, node, operand_type(state, conversion.source), value)
}

// A scalar broadcasting into a complex lane becomes a complex value with a zero imaginary part,
// matching the official scalar conversion into the complex element type.
@(private)
lower_array_complex_splat :: proc(state: ^Procedure_State, node: syntax.Node_Index, conversion: check.Conversion_Plan, elem: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	layout := state.job.layouts[elem]
	count: i64 = 4 if lower_type(state, elem).kind == .Quaternion else 2
	if layout.error != .None || layout.size % count != 0 { return lower_fail(state, node, .Operator) }
	component_size := layout.size / count
	scalar := component_scalar(component_size)
	if scalar != .F32 && scalar != .F64 { return lower_fail(state, node, .Operator) }
	value := lower_operand(state, conversion.source, 0)
	if state.failed || function.error != nil { return 0 }
	part := value
	if function.nodes.type[value] != scalar {
		#partial switch function.nodes.type[value] {
		case .I8, .I16, .I32, .I64:
			kind := ir.Node_Kind.Sint_To_Float if signed_type(state, operand_type(state, conversion.source)) else ir.Node_Kind.Uint_To_Float
			part = ir.convert(function, kind, value, scalar)
		case .F32, .F64:
			part = ir.convert(function, .Float_Ext if function.nodes.type[value] == .F32 else .Float_Trunc, value, scalar)
		case:
			return lower_fail(state, node, .Operator)
		}
	}
	slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	real := complex_real_index(lower_type(state, elem).kind)
	for index in 0 ..< count {
		lane := part if index == real else ir.const_float(function, scalar, 0)
		lower_store_word(state, ir.ptr_offset(function, slot, index * component_size), lane)
	}
	return slot
}

// Every lane of the result combines one lane of each operand; nested arrays recurse into their own lanes.
@(private)
lower_array_fill :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	type: types.Type_Id,
	slot: ir.Node_Id,
	left, right: Array_Factor,
) {
	if state.failed { return }
	shape := lower_type(state, type)
	if state.failed { return }
	size := state.job.layouts[shape.elem].size
	if state.job.layouts[shape.elem].error != .None || size <= 0 || size > i64(max(u32)) {
		lower_fail(state, node, .Operator)
		return
	}
	for index in 0 ..< shape.count {
		lane := lower_array_address(state, left, index, u32(size))
		if state.failed { return }
		other := lower_array_address(state, right, index, u32(size))
		if state.failed { return }
		lower_array_combine(state, node, operator, shape.elem, ir.ptr_offset(state.job.function, slot, index * size), lane, left.scalar, other, right.scalar)
		if state.failed { return }
	}
}

// One lane address: a broadcast scalar is the value itself, an aggregate lane is its offset address.
// Leaf code loads through the address exactly once, guided by the scalar flag.
@(private)
lower_array_address :: proc(state: ^Procedure_State, factor: Array_Factor, index: i64, element_size: u32) -> ir.Node_Id {
	if state.failed { return 0 }
	if factor.scalar { return factor.base }
	return ir.ptr_offset(state.job.function, factor.base, index * i64(element_size))
}

// One lane combines into its destination address; aggregate lanes recurse, scalar lanes apply directly.
@(private)
lower_array_combine :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	elem: types.Type_Id,
	destination, left: ir.Node_Id,
	left_scalar: bool,
	right: ir.Node_Id,
	right_scalar: bool,
) {
	if state.failed { return }
	kind := lower_type(state, elem).kind
	if state.failed { return }
	if kind == .Array || kind == .Enumerated_Array {
		inner := lower_type(state, elem)
		if state.failed { return }
		size := state.job.layouts[inner.elem].size
		if state.job.layouts[inner.elem].error != .None || size <= 0 || size > i64(max(u32)) {
			lower_fail(state, node, .Operator)
			return
		}
		for index in 0 ..< inner.count {
			lane := left if left_scalar else ir.ptr_offset(state.job.function, left, index * size)
			other := right if right_scalar else ir.ptr_offset(state.job.function, right, index * size)
			lower_array_combine(
				state,
				node,
				operator,
				inner.elem,
				ir.ptr_offset(state.job.function, destination, index * size),
				lane,
				left_scalar,
				other,
				right_scalar,
			)
			if state.failed { return }
		}
		return
	}
	first := left if left_scalar else lower_load(state, left, elem)
	if state.failed { return }
	second := right if right_scalar else lower_load(state, right, elem)
	if state.failed { return }
	value := lower_array_leaf(state, node, operator, first, second, elem)
	if state.failed { return }
	lower_store(state, destination, value, elem)
}

// One scalar lane: wide integers, bit sets and complex values have their own operators, the rest shares
// the scalar binary tail.
@(private)
lower_array_leaf :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	left, right: ir.Node_Id,
	elem: types.Type_Id,
) -> ir.Node_Id {
	if state.failed { return 0 }
	if is_wide_integer(state, elem) {
		return lower_wide_operator(state, node, operator, signed_type(state, elem), signed_type(state, elem), left, right)
	}
	if lower_type(state, elem).kind == .Bit_Set {
		return lower_bit_set_operator(state, node, operator, left, right)
	}
	if lower_complex_kind(state, elem) {
		return lower_complex_binary(state, node, operator, left, right, elem)
	}
	return lower_scalar_binary(state, node, operator, left, right, elem)
}

// A comparison reduces over all lanes to a single boolean: every lane equal for ==, any lane different for !=.
@(private)
lower_array_compare :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	array_type: types.Type_Id,
	left, right: Array_Factor,
) -> ir.Node_Id {
	if state.failed { return 0 }
	function := state.job.function
	shape := lower_type(state, array_type)
	if state.failed { return 0 }
	size := state.job.layouts[shape.elem].size
	if state.job.layouts[shape.elem].error != .None || size <= 0 || size > i64(max(u32)) {
		return lower_fail(state, node, .Operator)
	}
	accumulator := ir.const_int(function, .Bool, 1 if operator == .Cmp_Eq else 0)
	combine := ir.Node_Kind.And if operator == .Cmp_Eq else ir.Node_Kind.Or
	for index in 0 ..< shape.count {
		first := lower_array_address(state, left, index, u32(size))
		if state.failed { return 0 }
		second := lower_array_address(state, right, index, u32(size))
		if state.failed { return 0 }
		compared := lower_array_compare_lane(state, node, operator, shape.elem, first, left.scalar, second, right.scalar)
		if state.failed { return 0 }
		accumulator = ir.binary(function, combine, accumulator, compared)
	}
	return accumulator
}

// One comparison lane: nested arrays recurse, aggregates without scalar order compare through their
// generated equality, strings compare length then content, the rest compares directly.
@(private)
lower_array_compare_lane :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	elem: types.Type_Id,
	left: ir.Node_Id,
	left_scalar: bool,
	right: ir.Node_Id,
	right_scalar: bool,
) -> ir.Node_Id {
	if state.failed { return 0 }
	kind := lower_type(state, elem).kind
	if state.failed { return 0 }
	if kind == .Array || kind == .Enumerated_Array {
		return lower_array_compare(
			state,
			node,
			operator,
			elem,
			Array_Factor{base = left, scalar = left_scalar},
			Array_Factor{base = right, scalar = right_scalar},
		)
	}
	function := state.job.function
	first := left if left_scalar else lower_load(state, left, elem)
	if state.failed { return 0 }
	second := right if right_scalar else lower_load(state, right, elem)
	if state.failed { return 0 }
	if is_wide_integer(state, elem) {
		return lower_wide_operator(state, node, operator, signed_type(state, elem), signed_type(state, elem), first, second)
	}
	if kind == .Bit_Set {
		return lower_bit_set_operator(state, node, operator, first, second)
	}
	if kind == .Complex || kind == .Quaternion {
		return lower_complex_binary(state, node, operator, first, second, elem)
	}
	if kind == .String || kind == .String16 {
		equal := lower_array_string_equal(state, node, first, second, 2 if kind == .String16 else 1)
		if state.failed { return 0 }
		if operator == .Not_Eq { return ir.binary(function, .Xor, equal, ir.const_int(function, .Bool, 1)) }
		return equal
	}
	if kind == .CString || kind == .CString16 {
		equal := lower_array_cstring_equal(state, node, first, second, kind)
		if state.failed { return 0 }
		if operator == .Not_Eq { return ir.binary(function, .Xor, equal, ir.const_int(function, .Bool, 1)) }
		return equal
	}
	if kind == .Struct || kind == .Union {
		return lower_array_generated_equal(state, node, operator, elem, first, second)
	}
	if kind == .Float && !is_float16(state, elem) {
		return ir.compare(function, .FEq if operator == .Cmp_Eq else .FNe, first, second)
	}
	if is_float16(state, elem) {
		equal, ok := lower_float16_operation(function, operator, first, second)
		if !ok { return lower_fail(state, node, .Operator) }
		return equal
	}
	if kind == .Simd_Vector || kind == .Matrix {
		return lower_fail(state, node, .Operator)
	}
	return ir.compare(function, .Eq if operator == .Cmp_Eq else .Ne, first, second)
}

// Strings compare lengths first; a length mismatch makes the byte count zero, so content never reads past a string.
@(private)
lower_array_string_equal :: proc(state: ^Procedure_State, node: syntax.Node_Index, left, right: ir.Node_Id, unit: i64) -> ir.Node_Id {
	if state.failed { return 0 }
	function := state.job.function
	left_length := lower_load_word(state, ir.ptr_offset(function, left, 8), .I64)
	right_length := lower_load_word(state, ir.ptr_offset(function, right, 8), .I64)
	same := ir.compare(function, .Eq, left_length, right_length)
	count := ir.select(function, same, left_length, ir.const_int(function, .I64, 0))
	bytes := count
	if unit == 2 { bytes = ir.binary(function, .Shl, count, ir.const_int(function, .I64, 1)) }
	left_data := lower_load_word(state, left, .Ptr)
	right_data := lower_load_word(state, right, .Ptr)
	equal := lower_array_memory_equal(state, node, left_data, right_data, bytes)
	if state.failed { return 0 }
	return ir.binary(function, .And, same, equal)
}

// C strings compare their NUL-terminated lengths, then exactly those bytes.
@(private)
lower_array_cstring_equal :: proc(state: ^Procedure_State, node: syntax.Node_Index, left, right: ir.Node_Id, kind: types.Kind) -> ir.Node_Id {
	if state.failed { return 0 }
	left_length := lower_array_cstring_length(state, node, left, kind)
	if state.failed { return 0 }
	right_length := lower_array_cstring_length(state, node, right, kind)
	if state.failed { return 0 }
	function := state.job.function
	same := ir.compare(function, .Eq, left_length, right_length)
	unit := i64(1)
	if kind == .CString16 { unit = 2 }
	equal := lower_array_memory_equal(state, node, left, right, ir.binary(function, .Mul, left_length, ir.const_int(function, .I64, unit)))
	if state.failed { return 0 }
	return ir.binary(function, .And, same, equal)
}

// The NUL-terminated length of a cstring lane, mirroring the cstring conversion scan.
@(private)
lower_array_cstring_length :: proc(state: ^Procedure_State, node: syntax.Node_Index, value: ir.Node_Id, kind: types.Kind) -> ir.Node_Id {
	if state.failed { return 0 }
	function := state.job.function
	builder := state.builder
	unit := ir.Value_Type.I8
	stride := i64(1)
	if kind == .CString16 {
		unit = .I16
		stride = 2
	}
	length := ir.variable_declare(builder, ir.const_int(function, .I64, 0))
	end := ir.jump_target_make(builder)
	nil_check := ir.branch_if(builder, ir.compare(function, .Eq, value, ir.const_int(function, .Ptr, 0)))
	ir.enter_arm(builder, nil_check, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, nil_check, 1)
	cursor := ir.variable_declare(builder, value)
	loop := ir.loop_begin(builder, []ir.Variable{cursor, length})
	unit_value := ir.load(function, builder.control, ir.variable_get(builder, ir.MEMORY_VARIABLE), ir.variable_get(builder, cursor), unit, 0)
	terminator := ir.branch_if(builder, ir.compare(function, .Eq, unit_value, ir.const_int(function, unit, 0)))
	ir.enter_arm(builder, terminator, 0)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, terminator, 1)
	ir.variable_set(builder, cursor, ir.ptr_offset(function, ir.variable_get(builder, cursor), stride))
	ir.variable_set(builder, length, ir.binary(function, .Add, ir.variable_get(builder, length), ir.const_int(function, .I64, 1)))
	ir.loop_end(builder, loop)
	ir.seal_target(builder, end)
	return ir.variable_get(builder, length)
}

// Content comparison through the runtime memory_equal helper, like the generated equality does.
@(private)
lower_array_memory_equal :: proc(state: ^Procedure_State, node: syntax.Node_Index, left, right, count: ir.Node_Id) -> ir.Node_Id {
	if state.failed { return 0 }
	program := state.job.program
	for entity in program.runtime.helper_entities {
		if program.entities[entity].name != "memory_equal" { continue }
		symbol := state.job.symbols[program.entity_symbols[entity]]
		return generated_procedure_call(state, symbol, program.entities[entity].type, []ir.Node_Id{left, right, count})
	}
	return lower_fail(state, node, .Operator)
}

// Element-wise unary plus, minus and bitwise-not over fixed arrays; the unary dispatch hook lives in lower_expr.
@(private)
lower_array_unary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	operand_node: syntax.Node_Index,
	result: types.Type_Id,
) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	if operator != .Add && operator != .Sub && operator != .Xor { return lower_fail(state, node, .Operator) }
	shape := lower_type(state, result)
	if state.failed { return 0 }
	if shape.kind != .Array && shape.kind != .Enumerated_Array { return lower_fail(state, node, .Operator) }
	size := state.job.layouts[shape.elem].size
	if state.job.layouts[shape.elem].error != .None || size <= 0 || size > i64(max(u32)) {
		return lower_fail(state, node, .Operator)
	}
	function := state.job.function
	base := lower_array_base(state, operand_node)
	if state.failed || function.error != nil { return 0 }
	layout := state.job.layouts[result]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Operator) }
	slot := ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
	for index in 0 ..< shape.count {
		address := ir.ptr_offset(function, base, index * size)
		destination := ir.ptr_offset(function, slot, index * size)
		if is_wide_integer(state, shape.elem) {
			lane := lower_wide_unary(state, node, operator, address)
			if state.failed { return 0 }
			lower_store(state, destination, lane, shape.elem)
		} else if operator == .Add {
			lower_store(state, destination, lower_load(state, address, shape.elem), shape.elem)
		} else if lower_complex_kind(state, shape.elem) {
			lower_store(state, destination, lower_complex_unary(state, node, operator, address, shape.elem), shape.elem)
		} else {
			value := lower_load(state, address, shape.elem)
			if state.failed { return 0 }
			#partial switch operator {
			case .Sub:
				if is_float16(state, shape.elem) {
					negated, ok := lower_float16_operation(function, .Sub, lower_matrix_zero(state, shape.elem), value)
					if !ok { return lower_fail(state, node, .Operator) }
					value = negated
				} else if lower_type(state, shape.elem).kind == .Float {
					value = ir.unary(function, .FNeg, value)
				} else {
					value = ir.binary(function, .Sub, ir.const_int(function, function.nodes.type[value], 0), value)
				}
			case .Xor:
				// Official bitwise-not on boolean lanes is bytewise, so every lane reads back nonzero.
				if lower_type(state, shape.elem).kind == .Bool {
					value = ir.const_int(function, .Bool, 1)
				} else {
					value = ir.binary(function, .Xor, value, ir.const_int(function, function.nodes.type[value], -1))
				}
			}
			lower_store(state, destination, value, shape.elem)
		}
		if state.failed { return 0 }
	}
	return slot
}
// A compared value of generated-equality type calls its generated body; Not_Eq inverts the result.
@(private)
lower_array_generated_equal :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	type: types.Type_Id,
	left, right: ir.Node_Id,
) -> ir.Node_Id {
	if state.failed { return 0 }
	function := state.job.function
	lookup := types.resolve_named(check.type_store(state.job.program), type)
	for procedure in check.procedures(state.job.program) {
		if procedure.generated != (check.Generated_Body{kind = .Equality, type = lookup}) { continue }
		call := generated_procedure_call(state, state.job.symbols[procedure.symbol], procedure.signature, []ir.Node_Id{left, right})
		if operator == .Not_Eq { call = ir.binary(function, .Xor, call, ir.const_int(function, .Bool, 1)) }
		return call
	}
	return lower_fail(state, node, .Operator)
}

// The operand's resolved type id when it is a union, otherwise types.TYPE_NONE.
@(private)
lower_union_type :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> types.Type_Id {
	info := lower_info(state, node)
	if info.mode == .Type { return types.TYPE_NONE }
	store := check.type_store(state.job.program)
	resolved := types.resolve_named(store, info.type)
	if types.get(store, resolved).kind != .Union { return types.TYPE_NONE }
	return resolved
}

// The shared struct type when both operands resolve to the same struct, otherwise types.TYPE_NONE.
// Struct equality lowers through the checker's generated field-wise procedure, so padding never compares.
@(private)
lower_struct_compare_type :: proc(state: ^Procedure_State, left_node, right_node: syntax.Node_Index) -> types.Type_Id {
	store := check.type_store(state.job.program)
	left := types.resolve_named(store, lower_info(state, left_node).type)
	if types.get(store, left).kind != .Struct { return types.TYPE_NONE }
	right := types.resolve_named(store, lower_info(state, right_node).type)
	if right != left { return types.TYPE_NONE }
	return left
}

// Whether the operand's resolved type is a bit set, whose ordered comparison needs masks.
@(private)
lower_operand_is_bit_set :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> bool {
	store := check.type_store(state.job.program)
	return types.get(store, types.resolve_named(store, lower_operand_type(state, node))).kind == .Bit_Set
}

// One operand is the nil constant the checker unified into the other operand's type.
@(private)
lower_nil_operand :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> bool {
	info := lower_info(state, node)
	if info.constant == 0 { return false }
	constant := check.constant(state.job.program, info.constant)
	_, is_nil := constant.value.(check.Nil_Value)
	return is_nil
}

@(private)
lower_union_comparison :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	expression: syntax.Binary_Expr,
	compared_type: types.Type_Id,
	left, right: ir.Node_Id,
) -> ir.Node_Id {
	if state.failed { return 0 }
	union_type := compared_type
	if union_type == types.TYPE_NONE { union_type = lower_union_type(state, expression.left) }
	if union_type == types.TYPE_NONE { union_type = lower_union_type(state, expression.right) }
	if lower_nil_operand(state, expression.left) {
		return lower_union_nil_comparison(state, union_type, expression.op.kind, right)
	}
	if lower_nil_operand(state, expression.right) {
		return lower_union_nil_comparison(state, union_type, expression.op.kind, left)
	}
	if compared_type == types.TYPE_NONE &&
	   (lower_union_type(state, expression.left) != union_type || lower_union_type(state, expression.right) != union_type) {
		return lower_fail(state, node, .Operator)
	}
	return lower_union_equality(state, node, expression, union_type, left, right)
}

// Mirrors lb_emit_comp_against_nil: a zero-size union is always nil, a maybe-pointer union is its pointer word,
// every other union is its variant tag, which is zero for the nil variant.
@(private)
lower_union_nil_comparison :: proc(state: ^Procedure_State, union_type: types.Type_Id, operator: syntax.Token_Kind, address: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	descriptor := types.get(store, union_type)
	size, _, _ := types.layout(store, union_type)
	kind := ir.Node_Kind.Eq if operator == .Cmp_Eq else ir.Node_Kind.Ne
	if size == 0 { return ir.const_int(function, .Bool, i64(kind == .Eq)) }
	if descriptor.union_form == .Maybe_Pointer {
		word := lower_load_word(state, address, .Ptr)
		return ir.compare(function, kind, word, ir.const_int(function, .Ptr, 0))
	}
	layout, layout_error := types.union_layout(store, union_type)
	if layout_error != .None || layout.tag_size == 0 { return lower_fail(state, state.job.procedure.body.node, .Operator) }
	tag, tag_type := generated_union_tag(state, address, layout)
	return ir.compare(function, kind, tag, ir.const_int(function, tag_type, 0))
}

// Two union values compare through the generated equality body, mirroring lb_compare_records.
@(private)
lower_union_equality :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	expression: syntax.Binary_Expr,
	union_type: types.Type_Id,
	left, right: ir.Node_Id,
) -> ir.Node_Id {
	return lower_array_generated_equal(state, node, expression.op.kind, union_type, left, right)
}

// One `case` value of a switch on a union tag: `nil` tests the tag, any other value compares as a union equality.
lower_union_case_condition :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	union_type: types.Type_Id,
	tag: ir.Node_Id,
	value_node: syntax.Node_Index,
) -> ir.Node_Id {
	if lower_nil_operand(state, value_node) { return lower_union_nil_comparison(state, union_type, .Cmp_Eq, tag) }
	value := lower_value(state, value_node)
	if state.failed { return 0 }
	return lower_array_generated_equal(state, node, .Cmp_Eq, union_type, tag, value)
}

@(private)
lower_short_circuit :: proc(
	state: ^Procedure_State,
	operator: syntax.Token_Kind,
	right: syntax.Node_Index,
	left: ir.Node_Id,
	conversion := check.Plan_Id(0),
) -> ir.Node_Id {
	builder := state.builder
	count := len(builder.values)
	result := ir.variable_declare(builder, left)
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, left)
	short_arm := 0 if operator == .Cmp_Or || operator == .Cmp_Or_Eq else 1
	ir.enter_arm(builder, branch, short_arm)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1 - short_arm)
	value: ir.Node_Id
	if conversion != 0 { value = lower_declared_conversion(state, right, conversion) } else { value = lower_value(state, right) }
	if state.failed { return 0 }
	ir.variable_set(builder, result, value)
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	value = ir.variable_get(builder, result)
	ir.variables_truncate(builder, count)
	return value
}

@(private)
lower_integer_division :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	signed: bool,
	left, right: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	if function.nodes.kind[right] == .Const_Int && ir.node_int_value(function, right) != 0 {
		return lower_nonzero_division(state, operator, signed, left, right)
	}
	mode := check.sources(state.job.program)[int(state.job.procedure.body.file) - 1].policy.division_by_zero
	assert(mode != .Unspecified, "checker must resolve integer division policy")
	builder := state.builder
	type := function.nodes.type[left]
	count := len(builder.values)
	result := ir.variable_declare(builder, ir.undef(function, type))
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, ir.compare(function, .Ne, right, ir.const_int(function, type, 0)))
	ir.enter_arm(builder, branch, 0)
	ir.variable_set(builder, result, lower_nonzero_division(state, operator, signed, left, right))
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	if mode == .Trap {
		ir.emit_trap(builder)
	} else {
		value: ir.Node_Id
		if operator == .Quo {
			#partial switch mode {
			case .Zero:
				value = ir.const_int(function, type, 0)
			case .Self:
				value = left
			case .All_Bits:
				value = ir.const_int(function, type, -1)
			case:
				unreachable()
			}
		} else {
			value = ir.const_int(function, type, 0) if mode == .Self else left
		}
		ir.variable_set(builder, result, value)
		ir.jump_to(builder, end)
	}
	ir.seal_target(builder, end)
	value := ir.variable_get(builder, result)
	ir.variables_truncate(builder, count)
	return value
}

@(private)
lower_nonzero_division :: proc(state: ^Procedure_State, operator: syntax.Token_Kind, signed: bool, left, right: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	if operator == .Quo {
		return ir.divide(function, .SDiv if signed else .UDiv, state.builder.control, left, right)
	}
	if !signed { return ir.divide(function, .URem, state.builder.control, left, right) }
	type := function.nodes.type[right]
	zero := ir.const_int(function, type, 0)
	minus_one := ir.const_int(function, type, -1)
	safe_divisor := ir.select(function, ir.compare(function, .Eq, right, minus_one), ir.const_int(function, type, 1), right)
	remainder := ir.divide(function, .SRem, state.builder.control, left, safe_divisor)
	if operator != .Mod_Mod { return remainder }
	different_signs := ir.compare(function, .SLt, ir.binary(function, .Xor, left, right), zero)
	nonzero := ir.compare(function, .Ne, remainder, zero)
	adjust := ir.binary(function, .And, different_signs, nonzero)
	return ir.select(function, adjust, ir.binary(function, .Add, remainder, right), remainder)
}
