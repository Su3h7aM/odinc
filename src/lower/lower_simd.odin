package lower

import "core:math/big"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A `#simd` value is the address of a stack slot holding its lanes, as an aggregate is. Each lane is one scalar
// access, so the interpreter and every backend see only scalar nodes.
@(private)
lower_simd_builtin :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> (
	value: ir.Node_Id,
	handled: bool,
) {
	#partial switch kind {
	case .Unaligned_Load,
	     .Simd_Extract,
	     .Simd_Extract_Msbs,
	     .Simd_Replace,
	     .Simd_Indices,
	     .Simd_Select,
	     .Simd_Lanes_Eq,
	     .Simd_Lanes_Ne,
	     .Simd_Lanes_Lt,
	     .Simd_Lanes_Le,
	     .Simd_Lanes_Gt,
	     .Simd_Lanes_Ge,
	     .Simd_Add,
	     .Simd_Sub,
	     .Simd_Mul,
	     .Simd_Div,
	     .Simd_Bit_And,
	     .Simd_Bit_Or,
	     .Simd_Bit_Xor,
	     .Simd_Bit_And_Not,
	     .Simd_Min,
	     .Simd_Max,
	     .Simd_Reduce_Or,
	     .Simd_Shl,
	     .Simd_Shr,
	     .Simd_Shl_Masked,
	     .Simd_Shr_Masked,
	     .Simd_Reduce_Min,
	     .Simd_Reduce_Max:
		return lower_simd_operation(state, node, info, plan, kind), true
	case .Simd_Shuffle:
		return lower_simd_shuffle(state, node, info, plan), true
	}
	return 0, false
}

@(private)
lower_simd_operation :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	if info.type == 0 || kind == .Simd_Extract && len(plan.arguments) != 2 { return lower_fail(state, node, .Builtin) }
	values, ok := lower_intrinsic_operands(state, node, plan)
	if !ok { return 0 }
	function := state.job.function
	#partial switch kind {
	case .Simd_Extract_Msbs:
		if len(plan.arguments) != 1 { return lower_fail(state, node, .Builtin) }
		return lower_simd_extract_msbs(state, node, info.type, operand_type(state, plan.arguments[0]), values[0])
	case .Unaligned_Load:
		if len(plan.arguments) != 1 || function.nodes.type[values[0]] != .Ptr { return lower_fail(state, node, .Builtin) }
		if scalar_type(state, info.type) != .None { return lower_load(state, values[0], info.type) }
		copy := simd_slot(state, info.type)
		lower_store(state, copy, values[0], info.type)
		return copy
	case .Simd_Extract:
		vector := lower_type(state, operand_type(state, plan.arguments[0]))
		if vector.kind != .Simd_Vector || vector.elem != info.type || function.nodes.type[values[0]] != .Ptr || !is_integer_value(function, values[1]) {
			return lower_fail(state, node, .Builtin)
		}
		layout := state.job.layouts[vector.elem]
		if layout.error != .None || layout.size <= 0 || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
		return lower_load(state, ir.ptr_index(function, values[0], simd_lane_operand(state, plan.arguments[1], values[1]), u32(layout.size)), vector.elem)
	case .Simd_Replace:
		vector := lower_type(state, operand_type(state, plan.arguments[0]))
		if len(plan.arguments) != 3 ||
		   vector.kind != .Simd_Vector ||
		   vector.elem != operand_type(state, plan.arguments[2]) ||
		   function.nodes.type[values[0]] != .Ptr ||
		   !is_integer_value(function, values[1]) {
			return lower_fail(state, node, .Builtin)
		}
		layout := state.job.layouts[vector.elem]
		if layout.error != .None || layout.size <= 0 || layout.size > i64(max(u32)) { return lower_fail(state, node, .Builtin) }
		copy := simd_slot(state, info.type)
		lower_store(state, copy, values[0], info.type)
		lower_store(state, ir.ptr_index(function, copy, simd_lane_operand(state, plan.arguments[1], values[1]), u32(layout.size)), values[2], vector.elem)
		return copy
	case .Simd_Indices:
		if len(plan.arguments) != 0 { return lower_fail(state, node, .Builtin) }
		return lower_simd_indices(state, node, info.type)
	case .Simd_Select:
		if len(plan.arguments) != 3 { return lower_fail(state, node, .Builtin) }
		return lower_simd_select(state, info.type, operand_type(state, plan.arguments[0]), values)
	case .Simd_Lanes_Eq, .Simd_Lanes_Ne, .Simd_Lanes_Lt, .Simd_Lanes_Le, .Simd_Lanes_Gt, .Simd_Lanes_Ge:
		if len(plan.arguments) != 2 { return lower_fail(state, node, .Builtin) }
		return lower_simd_lanes(state, info.type, operand_type(state, plan.arguments[0]), kind, values)
	case .Simd_Add, .Simd_Sub, .Simd_Mul, .Simd_Div, .Simd_Bit_And, .Simd_Bit_Or, .Simd_Bit_Xor, .Simd_Bit_And_Not, .Simd_Min, .Simd_Max:
		if len(plan.arguments) != 2 { return lower_fail(state, node, .Builtin) }
		return lower_simd_lanewise(state, info.type, kind, values)
	case .Simd_Shl, .Simd_Shr, .Simd_Shl_Masked, .Simd_Shr_Masked:
		if len(plan.arguments) != 2 { return lower_fail(state, node, .Builtin) }
		return lower_simd_shift(state, info.type, operand_type(state, plan.arguments[1]), kind, values)
	case .Simd_Reduce_Or, .Simd_Reduce_Min, .Simd_Reduce_Max:
		if len(plan.arguments) != 1 { return lower_fail(state, node, .Builtin) }
		return lower_simd_reduce(state, node, kind, operand_type(state, plan.arguments[0]), values[0])
	}
	return lower_fail(state, node, .Builtin)
}

@(private)
lower_simd_extract_msbs :: proc(state: ^Procedure_State, node: syntax.Node_Index, result_type, vector_type: types.Type_Id, address: ir.Node_Id) -> ir.Node_Id {
	vector := lower_type(state, vector_type)
	result := lower_type(state, result_type)
	if vector.kind != .Simd_Vector ||
	   vector.count < 1 ||
	   vector.count > 128 ||
	   result.kind != .Bit_Set ||
	   result.lower_bound != 0 ||
	   result.upper_bound != vector.count - 1 {
		return lower_fail(state, node, .Builtin)
	}
	element := lower_type(state, vector.elem)
	layout := state.job.layouts[vector.elem]
	if element.kind != .Integer && element.kind != .Bool || layout.error != .None {
		return lower_fail(state, node, .Builtin)
	}
	word_type: ir.Value_Type
	switch layout.size {
	case 1:
		word_type = .I8
	case 2:
		word_type = .I16
	case 4:
		word_type = .I32
	case 8, 16:
		word_type = .I64
	case:
		return lower_fail(state, node, .Builtin)
	}
	function := state.job.function
	zero := ir.const_int(function, .I64, 0)
	words := Wide_Words {
		low  = zero,
		high = zero,
	}
	for lane in 0 ..< vector.count {
		lane_address := ir.ptr_offset(function, address, lane * layout.size)
		if layout.size == 16 { lane_address = ir.ptr_offset(function, lane_address, 8) }
		value := lower_load_word(state, lane_address, word_type)
		bit := ir.binary(function, .Shr, value, ir.const_int(function, .I64, min(layout.size, 8) * 8 - 1))
		if word_type != .I64 { bit = ir.convert(function, .Zext, bit, .I64) }
		bit = ir.binary(function, .Shl, bit, ir.const_int(function, .I64, lane % 64))
		if lane < 64 {
			words.low = ir.binary(function, .Or, words.low, bit)
		} else {
			words.high = ir.binary(function, .Or, words.high, bit)
		}
	}
	if is_wide_integer(state, result_type) { return wide_store(state, words) }
	scalar := scalar_type(state, result_type)
	if scalar == .None { return lower_fail(state, node, .Builtin) }
	if scalar == .I64 { return words.low }
	return ir.convert(function, .Trunc, words.low, scalar)
}

@(private)
lower_simd_indices :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	lane_type := scalar_type(state, elem)
	if !is_integer_type(lane_type) && lane_type != .F16 && lane_type != .F32 && lane_type != .F64 { return lower_fail(state, node, .Builtin) }
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		lane_value := simd_lane_index(function, lane_type, lane)
		if is_float16(state, elem) { lane_value = float16_narrow(function, ir.const_float(function, .F64, transmute(u64)f64(lane))) }
		lower_store(state, simd_lane_address(state, address, lane, elem), lane_value, elem)
	}
	return address
}

@(private)
simd_lane_index :: proc(function: ^ir.Function, lane_type: ir.Value_Type, lane: i64) -> ir.Node_Id {
	#partial switch lane_type {
	case .F32:
		return ir.const_float(function, lane_type, u64(transmute(u32)f32(lane)))
	case .F64:
		return ir.const_float(function, lane_type, transmute(u64)f64(lane))
	}
	return ir.const_int(function, lane_type, lane)
}

@(private)
simd_lane_operand :: proc(state: ^Procedure_State, operand: check.Operand, value: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	if function.nodes.type[value] == .I64 { return value }
	return ir.convert(function, .Sext if signed_type(state, operand_type(state, operand)) else .Zext, value, .I64)
}

@(private)
lower_simd_select :: proc(state: ^Procedure_State, type, mask_type: types.Type_Id, values: [5]ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	mask_elem, _ := simd_shape(state, mask_type)
	mask_is_bool := lower_type(state, mask_elem).kind == .Bool
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		condition := simd_lane_value(state, values[0], lane, mask_elem)
		if !mask_is_bool {
			condition = ir.compare(function, .Ne, condition, ir.const_int(function, scalar_type(state, mask_elem), 0))
		}
		chosen := ir.select(function, condition, simd_lane_value(state, values[1], lane, elem), simd_lane_value(state, values[2], lane, elem))
		lower_store(state, simd_lane_address(state, address, lane, elem), chosen, elem)
	}
	return address
}

@(private)
lower_simd_lanes :: proc(state: ^Procedure_State, type, operand: types.Type_Id, kind: check.Builtin_Kind, values: [5]ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	input_elem, lanes := simd_shape(state, operand)
	output_elem, _ := simd_shape(state, type)
	floating := lower_type(state, input_elem).kind == .Float
	compare_kind := simd_compare_kind(kind, floating, signed_type(state, input_elem))
	lane_type := scalar_type(state, output_elem)
	all_ones := ir.const_int(function, lane_type, -1)
	none := ir.const_int(function, lane_type, 0)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		left := simd_lane_value(state, values[0], lane, input_elem)
		right := simd_lane_value(state, values[1], lane, input_elem)
		if kind == .Simd_Lanes_Gt || kind == .Simd_Lanes_Ge { left, right = right, left }
		holds := ir.compare(function, compare_kind, left, right)
		lower_store(state, simd_lane_address(state, address, lane, output_elem), ir.select(function, holds, all_ones, none), output_elem)
	}
	return address
}

@(private)
simd_compare_kind :: proc(kind: check.Builtin_Kind, floating, signed: bool) -> ir.Node_Kind {
	#partial switch kind {
	case .Simd_Lanes_Eq:
		return .FEq if floating else .Eq
	case .Simd_Lanes_Ne:
		return .FNe if floating else .Ne
	case .Simd_Lanes_Lt, .Simd_Lanes_Gt:
		if floating { return .FLt }
		return .SLt if signed else .ULt
	}
	if floating { return .FLe }
	return .SLe if signed else .ULe
}

@(private)
lower_simd_reduce :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	kind: check.Builtin_Kind,
	vector_type: types.Type_Id,
	vector: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, vector_type)
	floating := lower_type(state, elem).kind == .Float
	less_kind := ir.Node_Kind.SLt if signed_type(state, elem) else ir.Node_Kind.ULt
	half := is_float16(state, elem)
	accumulator := simd_lane_value(state, vector, 0, elem)
	if half { accumulator = float16_widen(function, accumulator) }
	for lane in 1 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		next := simd_lane_value(state, vector, lane, elem)
		if half { next = float16_widen(function, next) }
		if kind == .Simd_Reduce_Or {
			accumulator = ir.binary(function, .Or, accumulator, next)
		} else if floating {
			accumulator = pick_float_extreme(function, accumulator, next, kind == .Simd_Reduce_Min)
		} else {
			accumulator = pick_ordered(function, less_kind, accumulator, next, kind == .Simd_Reduce_Min)
		}
	}
	if half { accumulator = float16_from_f32(function, accumulator) }
	return accumulator
}

// Floating reductions ignore a NaN operand when the other operand is a number.
@(private)
pick_float_extreme :: proc(function: ^ir.Function, accumulator, next: ir.Node_Id, want_min: bool) -> ir.Node_Id {
	next_less := ir.compare(function, .FLt, next, accumulator) if want_min else ir.compare(function, .FLt, accumulator, next)
	accumulator_nan := ir.compare(function, .FNe, accumulator, accumulator)
	choose_next := ir.binary(function, .Or, next_less, accumulator_nan)
	lane_type := function.nodes.type[accumulator]
	integer_type := ir.Value_Type.I16 if lane_type == .F16 else ir.Value_Type.I32 if lane_type == .F32 else ir.Value_Type.I64
	zero := ir.const_float(function, lane_type, 0)
	accumulator_zero := ir.compare(function, .FEq, accumulator, zero)
	next_zero := ir.compare(function, .FEq, next, zero)
	next_sign := ir.convert(function, .Bitcast, next, integer_type)
	next_negative := ir.compare(function, .SLt, next_sign, ir.const_int(function, integer_type, 0))
	preferred_sign := next_negative if want_min else bool_not(function, next_negative)
	zero_preference := ir.binary(function, .And, accumulator_zero, ir.binary(function, .And, next_zero, preferred_sign))
	choose_next = ir.binary(function, .Or, choose_next, zero_preference)
	return ir.select(function, choose_next, next, accumulator)
}

// Broadcast of a typed scalar into every lane, from `lower_conversion`.
@(private)
lower_simd_broadcast :: proc(state: ^Procedure_State, type: types.Type_Id, value: ir.Node_Id) -> ir.Node_Id {
	elem, lanes := simd_shape(state, type)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || state.job.function.error != nil { return 0 }
		lower_store(state, simd_lane_address(state, address, lane, elem), value, elem)
	}
	return address
}

@(private)
simd_shape :: proc(state: ^Procedure_State, type: types.Type_Id) -> (elem: types.Type_Id, lanes: i64) {
	descriptor := lower_type(state, type)
	return descriptor.elem, descriptor.count
}

@(private)
simd_slot :: proc(state: ^Procedure_State, type: types.Type_Id) -> ir.Node_Id {
	layout := state.job.layouts[type]
	return ir.stack_slot(state.job.function, state.entry_control, u32(layout.size), u32(layout.align))
}

@(private)
simd_lane_address :: proc(state: ^Procedure_State, vector: ir.Node_Id, lane: i64, elem: types.Type_Id) -> ir.Node_Id {
	return ir.ptr_offset(state.job.function, vector, lane * state.job.layouts[elem].size)
}

@(private)
simd_lane_value :: proc(state: ^Procedure_State, vector: ir.Node_Id, lane: i64, elem: types.Type_Id) -> ir.Node_Id {
	return lower_load(state, simd_lane_address(state, vector, lane, elem), elem)
}

// Each result lane copies one lane of the operands; indices at or past the operand width select from the second operand.
@(private)
lower_simd_shuffle :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	if len(plan.arguments) < 3 || !call_operand_valid(state, plan.arguments[0]) || !call_operand_valid(state, plan.arguments[1]) {
		return lower_fail(state, node, .Builtin)
	}
	function := state.job.function
	left := lower_operand(state, plan.arguments[0])
	right := lower_operand(state, plan.arguments[1])
	if state.failed || function.error != nil { return 0 }
	input_elem, input_lanes := simd_shape(state, operand_type(state, plan.arguments[0]))
	elem, lanes := simd_shape(state, info.type)
	if elem != input_elem || lanes != i64(len(plan.arguments) - 2) { return lower_fail(state, node, .Builtin) }
	address := simd_slot(state, info.type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		index_constant, is_constant := plan.arguments[lane + 2].(check.Const_Id)
		if !is_constant { return lower_fail(state, node, .Builtin) }
		integer := check.constant(state.job.program, index_constant).value.(big.Int)
		index, index_error := big.int_get_i64(&integer)
		if index_error != nil || index < 0 || index >= 2 * input_lanes { return lower_fail(state, node, .Builtin) }
		source, source_lane := left, index
		if index >= input_lanes { source, source_lane = right, index - input_lanes }
		lower_store(state, simd_lane_address(state, address, lane, elem), simd_lane_value(state, source, source_lane, elem), elem)
	}
	return address
}
@(private)
lower_simd_lanewise :: proc(state: ^Procedure_State, type: types.Type_Id, kind: check.Builtin_Kind, values: [5]ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	floating := lower_type(state, elem).kind == .Float
	signed := signed_type(state, elem)
	lane_type := scalar_type(state, elem)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		left := simd_lane_value(state, values[0], lane, elem)
		right := simd_lane_value(state, values[1], lane, elem)
		result: ir.Node_Id
		#partial switch kind {
		case .Simd_Min, .Simd_Max:
			less_kind := ir.Node_Kind.FLt if floating else ir.Node_Kind.SLt if signed else ir.Node_Kind.ULt
			less := ir.compare(function, less_kind, left, right)
			result = ir.select(function, less, left, right) if kind == .Simd_Min else ir.select(function, less, right, left)
		case .Simd_Bit_And_Not:
			not_right := ir.binary(function, .Xor, right, ir.const_int(function, lane_type, -1))
			result = ir.binary(function, .And, left, not_right)
		case:
			result = ir.binary(function, simd_arithmetic_kind(kind, floating), left, right)
		}
		lower_store(state, simd_lane_address(state, address, lane, elem), result, elem)
	}
	return address
}

@(private)
simd_arithmetic_kind :: proc(kind: check.Builtin_Kind, floating: bool) -> ir.Node_Kind {
	#partial switch kind {
	case .Simd_Add:
		return .FAdd if floating else .Add
	case .Simd_Sub:
		return .FSub if floating else .Sub
	case .Simd_Mul:
		return .FMul if floating else .Mul
	case .Simd_Div:
		return .FDiv
	case .Simd_Bit_And:
		return .And
	case .Simd_Bit_Or:
		return .Or
	}
	return .Xor
}

@(private)
lower_simd_shift :: proc(state: ^Procedure_State, type, amount_type: types.Type_Id, kind: check.Builtin_Kind, values: [5]ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	amount_elem, _ := simd_shape(state, amount_type)
	lane_type := scalar_type(state, elem)
	amount_type_value := scalar_type(state, amount_elem)
	bits := state.job.layouts[elem].size * 8
	shift_kind := ir.Node_Kind.Shl
	if kind == .Simd_Shr || kind == .Simd_Shr_Masked {
		shift_kind = .Sar if signed_type(state, elem) else .Shr
	}
	masked := kind == .Simd_Shl_Masked || kind == .Simd_Shr_Masked
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		value := simd_lane_value(state, values[0], lane, elem)
		amount := simd_lane_value(state, values[1], lane, amount_elem)
		in_range := ir.compare(function, .ULt, amount, ir.const_int(function, amount_type_value, bits))
		if amount_type_value != lane_type {
			amount = ir.convert(function, .Trunc if state.job.layouts[amount_elem].size > state.job.layouts[elem].size else .Zext, amount, lane_type)
		}
		amount = ir.binary(function, .And, amount, ir.const_int(function, lane_type, bits - 1))
		shifted := ir.binary(function, shift_kind, value, amount)
		result := shifted
		if !masked { result = ir.select(function, in_range, shifted, ir.const_int(function, lane_type, 0)) }
		lower_store(state, simd_lane_address(state, address, lane, elem), result, elem)
	}
	return address
}
