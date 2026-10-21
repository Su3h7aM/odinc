package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Complex and quaternion values are aggregates of floats, each component at its index times the component size.
@(private)
component_scalar :: proc(component_size: i64) -> ir.Value_Type {
	return .F32 if component_size == 4 else .F64
}

@(private)
component_count :: proc(kind: check.Builtin_Kind) -> i64 {
	return 4 if kind == .Quaternion else 2
}

@(private)
lower_complex_builtin :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	function := state.job.function
	layout := state.job.layouts[info.type]
	if kind == .Complex || kind == .Quaternion {
		count := component_count(kind)
		if i64(len(plan.arguments)) != count || layout.error != .None || layout.size % count != 0 { return lower_fail(state, node, .Builtin) }
		slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
		for operand, index in plan.arguments {
			value := lower_operand(state, operand)
			if state.failed || function.error != nil { return 0 }
			lower_store_word(state, ir.ptr_offset(function, slot, i64(index) * layout.size / count), value)
		}
		return slot
	}
	if kind == .Conj {
		return lower_complex_conj(state, node, info, plan)
	}
	scalar := scalar_type(state, info.type)
	if len(plan.arguments) != 1 || scalar == .None { return lower_fail(state, node, .Builtin) }
	address := lower_operand(state, plan.arguments[0])
	if state.failed || function.error != nil { return 0 }
	aggregate := lower_type(state, operand_type(state, plan.arguments[0]))
	if aggregate.kind != .Complex && aggregate.kind != .Quaternion { return lower_fail(state, node, .Builtin) }
	index: i64
	#partial switch kind {
	case .Real:
		index = complex_real_index(aggregate.kind)
	case .Imag:
		index = 1 if aggregate.kind == .Complex else 0
	case .Jmag:
		if aggregate.kind != .Quaternion { return lower_fail(state, node, .Builtin) }
		index = 1
	case .Kmag:
		if aggregate.kind != .Quaternion { return lower_fail(state, node, .Builtin) }
		index = 2
	case:
		return lower_fail(state, node, .Builtin)
	}
	return lower_load_word(state, ir.ptr_offset(function, address, index * layout.size), scalar)
}

// A complex value stores the real part first; a quaternion stores the three imaginary parts first and the real
// part last, matching the upstream memory layout.
@(private)
complex_real_index :: proc(kind: types.Kind) -> i64 {
	return 3 if kind == .Quaternion else 0
}

// Components narrower than f32 load as their bit pattern; negation then flips the sign bit directly.
@(private)
complex_part_scalar :: proc(component_size: i64) -> ir.Value_Type {
	if component_size == 2 { return .I16 }
	if component_size == 4 { return .F32 }
	return .F64
}

@(private)
complex_negate :: proc(function: ^ir.Function, part: ir.Node_Id, component_size: i64) -> ir.Node_Id {
	if component_size == 2 { return float16_negate(function, part) }
	return ir.unary(function, .FNeg, part)
}

// The conjugate keeps the real part and negates every imaginary part.
@(private)
lower_complex_conj :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	function := state.job.function
	if len(plan.arguments) != 1 || !call_operand_valid(state, plan.arguments[0]) { return lower_fail(state, node, .Builtin) }
	operand := operand_type(state, plan.arguments[0])
	aggregate := lower_type(state, operand)
	count: i64
	#partial switch aggregate.kind {
	case .Complex:
		count = 2
	case .Quaternion:
		count = 4
	case:
		return lower_fail(state, node, .Builtin)
	}
	operand_layout := state.job.layouts[operand]
	result_layout := state.job.layouts[info.type]
	if operand_layout.error != .None || result_layout.error != .None || operand_layout.size != result_layout.size {
		return lower_fail(state, node, .Builtin)
	}
	if operand_layout.size % count != 0 { return lower_fail(state, node, .Builtin) }
	component_size := operand_layout.size / count
	if component_size != 2 && component_size != 4 && component_size != 8 { return lower_fail(state, node, .Builtin) }
	address := lower_operand(state, plan.arguments[0])
	if state.failed || function.error != nil { return 0 }
	slot := ir.stack_slot(function, state.entry_control, u32(result_layout.size), u32(result_layout.align))
	scalar := complex_part_scalar(component_size)
	real := complex_real_index(aggregate.kind)
	for index in 0 ..< count {
		part := lower_complex_part(state, address, index, component_size, scalar)
		if index != real { part = complex_negate(function, part, component_size) }
		lower_store_word(state, ir.ptr_offset(function, slot, index * component_size), part)
	}
	return slot
}

// The magnitude is the square root of the sum of the squared components. The f16 widths have no official
// runtime value (the official compiler exits 132 for a missing `abs_complex32` or `abs_quaternion64`), so they
// report unsupported instead of inventing one.
@(private)
lower_complex_abs :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	function := state.job.function
	if len(plan.arguments) != 1 || !call_operand_valid(state, plan.arguments[0]) { return lower_fail(state, node, .Builtin) }
	operand := operand_type(state, plan.arguments[0])
	aggregate := lower_type(state, operand)
	count: i64
	#partial switch aggregate.kind {
	case .Complex:
		count = 2
	case .Quaternion:
		count = 4
	case:
		return lower_fail(state, node, .Builtin)
	}
	layout := state.job.layouts[operand]
	if layout.error != .None || layout.size % count != 0 { return lower_fail(state, node, .Builtin) }
	component_size := layout.size / count
	scalar := complex_part_scalar(component_size)
	if scalar != .F32 && scalar != .F64 { return lower_fail(state, node, .Builtin) }
	if scalar_type(state, info.type) != scalar { return lower_fail(state, node, .Builtin) }
	address := lower_operand(state, plan.arguments[0])
	if state.failed || function.error != nil { return 0 }
	total: ir.Node_Id
	for index in 0 ..< count {
		part := lower_complex_part(state, address, index, component_size, scalar)
		square := ir.binary(function, .FMul, part, part)
		total = square if index == 0 else ir.binary(function, .FAdd, total, square)
	}
	return ir.unary(function, .FSqrt, total)
}

@(private)
lower_complex_kind :: proc(state: ^Procedure_State, type: types.Type_Id) -> bool {
	kind := lower_type(state, type).kind
	return kind == .Complex || kind == .Quaternion
}

@(private)
lower_complex_part :: proc(state: ^Procedure_State, address: ir.Node_Id, index: i64, component_size: i64, scalar: ir.Value_Type) -> ir.Node_Id {
	return lower_load_word(state, ir.ptr_offset(state.job.function, address, index * component_size), scalar)
}

@(private)
lower_complex_unary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	operand: ir.Node_Id,
	type: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	layout := state.job.layouts[type]
	count: i64 = 4 if lower_type(state, type).kind == .Quaternion else 2
	if operator != .Add && operator != .Sub { return lower_fail(state, node, .Operator) }
	if layout.error != .None || layout.size % count != 0 { return lower_fail(state, node, .Operator) }
	component_size := layout.size / count
	scalar := component_scalar(component_size)
	slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	for index in 0 ..< count {
		part := lower_complex_part(state, operand, index, component_size, scalar)
		if operator == .Sub { part = ir.unary(function, .FNeg, part) }
		lower_store_word(state, ir.ptr_offset(function, slot, index * component_size), part)
	}
	return slot
}

// Complex and quaternion operators work componentwise; multiplication and division are complex only.
@(private)
lower_complex_binary :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	left, right: ir.Node_Id,
	type: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	layout := state.job.layouts[type]
	count: i64 = 4 if lower_type(state, type).kind == .Quaternion else 2
	if layout.error != .None || layout.size % count != 0 { return lower_fail(state, node, .Operator) }
	component_size := layout.size / count
	scalar := component_scalar(component_size)
	#partial switch operator {
	case .Add, .Sub:
		slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
		for index in 0 ..< count {
			first := lower_complex_part(state, left, index, component_size, scalar)
			second := lower_complex_part(state, right, index, component_size, scalar)
			value := ir.binary(function, .FAdd if operator == .Add else .FSub, first, second)
			lower_store_word(state, ir.ptr_offset(function, slot, index * component_size), value)
		}
		return slot
	case .Cmp_Eq, .Not_Eq:
		result: ir.Node_Id
		for index in 0 ..< count {
			first := lower_complex_part(state, left, index, component_size, scalar)
			second := lower_complex_part(state, right, index, component_size, scalar)
			compare_kind := ir.Node_Kind.FEq if operator == .Cmp_Eq else ir.Node_Kind.FNe
			component_result := ir.compare(function, compare_kind, first, second)
			if index == 0 {
				result = component_result
			} else {
				result = ir.binary(function, .And if operator == .Cmp_Eq else .Or, result, component_result)
			}
		}
		return result
	case .Mul, .Quo:
		if count != 2 { return lower_fail(state, node, .Operator) }
		a := lower_complex_part(state, left, 0, component_size, scalar)
		b := lower_complex_part(state, left, 1, component_size, scalar)
		c := lower_complex_part(state, right, 0, component_size, scalar)
		d := lower_complex_part(state, right, 1, component_size, scalar)
		slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
		real_part, imaginary_part: ir.Node_Id
		if operator == .Mul {
			real_part = ir.binary(function, .FSub, ir.binary(function, .FMul, a, c), ir.binary(function, .FMul, b, d))
			imaginary_part = ir.binary(function, .FAdd, ir.binary(function, .FMul, a, d), ir.binary(function, .FMul, b, c))
		} else {
			denominator := ir.binary(function, .FAdd, ir.binary(function, .FMul, c, c), ir.binary(function, .FMul, d, d))
			real_part = ir.binary(function, .FDiv, ir.binary(function, .FAdd, ir.binary(function, .FMul, a, c), ir.binary(function, .FMul, b, d)), denominator)
			imaginary_part = ir.binary(
				function,
				.FDiv,
				ir.binary(function, .FSub, ir.binary(function, .FMul, b, c), ir.binary(function, .FMul, a, d)),
				denominator,
			)
		}
		lower_store_word(state, slot, real_part)
		lower_store_word(state, ir.ptr_offset(function, slot, component_size), imaginary_part)
		return slot
	}
	return lower_fail(state, node, .Operator)
}

// Converts between complex widths (complex64 <-> complex128) componentwise.
@(private)
lower_complex_conversion :: proc(state: ^Procedure_State, node: syntax.Node_Index, operand: ir.Node_Id, source, target: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	source_layout := state.job.layouts[source]
	target_layout := state.job.layouts[target]
	count: i64 = 4 if lower_type(state, target).kind == .Quaternion else 2
	source_count: i64 = 4 if lower_type(state, source).kind == .Quaternion else 2
	if source_count != count || source_layout.error != .None || target_layout.error != .None { return lower_fail(state, node, .Conversion) }
	if source_layout.size % count != 0 || target_layout.size % count != 0 { return lower_fail(state, node, .Conversion) }
	source_size := source_layout.size / count
	target_size := target_layout.size / count
	source_scalar := component_scalar(source_size)
	target_scalar := component_scalar(target_size)
	slot := ir.stack_slot(function, state.entry_control, u32(target_layout.size), u32(target_layout.align))
	for index in 0 ..< count {
		part := lower_complex_part(state, operand, index, source_size, source_scalar)
		if source_scalar != target_scalar {
			part = ir.convert(function, .Float_Ext if target_size > source_size else .Float_Trunc, part, target_scalar)
		}
		lower_store_word(state, ir.ptr_offset(function, slot, index * target_size), part)
	}
	return slot
}

// Each component of a constant is a float constant, stored at its index times the component size.
@(private)
lower_component_constant :: proc(state: ^Procedure_State, components: []check.Const_Id, type: types.Type_Id) -> ir.Node_Id {
	layout := state.job.layouts[type]
	count := i64(len(components))
	if layout.error != .None || layout.size % count != 0 { return lower_fail(state, state.job.procedure.body.node, .Constant) }
	function := state.job.function
	scalar := component_scalar(layout.size / count)
	slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	is_quaternion := lower_type(state, type).kind == .Quaternion
	for component, index in components {
		constant := check.constant(state.job.program, component)
		value, is_float := constant.value.(check.Float_Value)
		if !is_float { return lower_fail(state, state.job.procedure.body.node, .Constant) }
		bits, bits_ok := lower_float_bits(value, scalar)
		if !bits_ok { return lower_fail(state, state.job.procedure.body.node, .Constant) }
		// A quaternion constant lists the real part first but stores it last.
		memory_index := index
		if is_quaternion { memory_index = (index + 3) % 4 }
		lower_store_word(state, ir.ptr_offset(function, slot, i64(memory_index) * layout.size / count), ir.const_float(function, scalar, bits))
	}
	return slot
}
