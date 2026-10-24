package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Lane-wise math, reductions by arithmetic and masked memory access on `#simd` vectors. Like every `#simd`
// operation here, each lane is a scalar node. The rounding operations follow `llvm.ceil`, `llvm.floor`,
// `llvm.trunc` and `llvm.nearbyint` (ties to even); the approximate reciprocals are exact.
@(private)
lower_simd_math :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	if info.type == 0 { return lower_fail(state, node, .Builtin) }
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return 0 }
	#partial switch kind {
	case .Simd_Saturating_Add, .Simd_Saturating_Sub:
		if len(plan.arguments) != 2 { return lower_fail(state, node, .Builtin) }
		return lower_simd_saturating(state, node, info.type, kind, values)
	case .Simd_Neg, .Simd_Abs, .Simd_Ceil, .Simd_Floor, .Simd_Trunc, .Simd_Nearest, .Simd_Approx_Recip, .Simd_Approx_Recip_Sqrt:
		if len(plan.arguments) != 1 { return lower_fail(state, node, .Builtin) }
		return lower_simd_unary(state, node, info.type, kind, values[0])
	case .Simd_Gather, .Simd_Masked_Load, .Simd_Masked_Expand_Load:
		if len(plan.arguments) != 3 { return lower_fail(state, node, .Builtin) }
		return lower_simd_masked_load(state, node, info.type, operand_type(state, plan.arguments[2]), kind, values)
	}
	if len(plan.arguments) != 1 { return lower_fail(state, node, .Builtin) }
	return lower_simd_reduce_arithmetic(state, node, kind, operand_type(state, plan.arguments[0]), values[0])
}

@(private)
lower_simd_saturating :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	type: types.Type_Id,
	kind: check.Builtin_Kind,
	values: []ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	lane_type := scalar_type(state, elem)
	if !is_integer_type(lane_type) { return lower_fail(state, node, .Builtin) }
	signed := signed_type(state, elem)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		left := simd_lane_value(state, values[0], lane, elem)
		right := simd_lane_value(state, values[1], lane, elem)
		result := saturating_value(state, kind == .Simd_Saturating_Add, signed, left, right)
		lower_store(state, simd_lane_address(state, address, lane, elem), result, elem)
	}
	return address
}

@(private)
lower_simd_unary :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id, kind: check.Builtin_Kind, vector: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	lane_type := scalar_type(state, elem)
	floating := lower_type(state, elem).kind == .Float
	if !floating && (!is_integer_type(lane_type) || kind != .Simd_Neg && kind != .Simd_Abs) { return lower_fail(state, node, .Builtin) }
	if floating && lane_type != .F32 && lane_type != .F64 && !is_float16(state, elem) { return lower_fail(state, node, .Builtin) }
	signed := signed_type(state, elem)
	half := is_float16(state, elem)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		value := simd_lane_value(state, vector, lane, elem)
		result: ir.Node_Id
		if !floating {
			result = simd_integer_unary(function, kind, signed, value)
		} else if kind == .Simd_Neg || kind == .Simd_Abs {
			result = simd_float_sign_operation(function, kind, value)
		} else {
			if half { value = float16_widen(function, value) }
			if lane_type == .F32 && !half && (kind == .Simd_Approx_Recip || kind == .Simd_Approx_Recip_Sqrt) {
				result = lower_approximation_instruction(state, node, kind, value)
			} else {
				result = simd_float_rounding_or_reciprocal(function, kind, value)
			}
			if half { result = float16_from_f32(function, result) }
		}
		lower_store(state, simd_lane_address(state, address, lane, elem), result, elem)
	}
	return address
}

// Single-precision lanes use the RCPSS and RSQRTSS instructions, as the official backend uses the packed forms
// whose lanes they match; other element types divide exactly.
@(private)
lower_approximation_instruction :: proc(state: ^Procedure_State, node: syntax.Node_Index, kind: check.Builtin_Kind, value: ir.Node_Id) -> ir.Node_Id {
	results: [1]ir.Node_Id
	operation := ir.Target_Op.Rcpss if kind == .Simd_Approx_Recip else ir.Target_Op.Rsqrtss
	lower_target_op(state, node, operation, {value}, results[:])
	return results[0]
}

@(private)
simd_integer_unary :: proc(function: ^ir.Function, kind: check.Builtin_Kind, signed: bool, value: ir.Node_Id) -> ir.Node_Id {
	type := function.nodes.type[value]
	zero := ir.const_int(function, type, 0)
	negated := ir.binary(function, .Sub, zero, value)
	if kind == .Simd_Neg { return negated }
	if !signed { return value }
	return ir.select(function, ir.compare(function, .SLt, value, zero), negated, value)
}

@(private)
simd_float_sign_operation :: proc(function: ^ir.Function, kind: check.Builtin_Kind, value: ir.Node_Id) -> ir.Node_Id {
	type := function.nodes.type[value]
	if kind == .Simd_Neg {
		if type == .I16 { return float16_negate(function, value) }
		return ir.unary(function, .FNeg, value)
	}
	if type == .I16 { return ir.binary(function, .And, value, ir.const_int(function, .I16, 0x7fff)) }
	integer_type := float_bits_type(type)
	bits := ir.convert(function, .Bitcast, value, integer_type)
	magnitude := ir.binary(function, .And, bits, ir.const_int(function, integer_type, float_magnitude_mask(integer_type)))
	return ir.convert(function, .Bitcast, magnitude, type)
}

@(private)
float_bits_type :: proc(type: ir.Value_Type) -> ir.Value_Type {
	return .I32 if type == .F32 else .I64
}

@(private)
float_magnitude_mask :: proc(integer_type: ir.Value_Type) -> i64 {
	return 0x7fffffff if integer_type == .I32 else max(i64)
}

// `value` is `F32` or `F64`.
@(private)
simd_float_rounding_or_reciprocal :: proc(function: ^ir.Function, kind: check.Builtin_Kind, value: ir.Node_Id) -> ir.Node_Id {
	type := function.nodes.type[value]
	one := ir.const_float(function, type, 0x3F800000 if type == .F32 else 0x3FF0000000000000)
	#partial switch kind {
	case .Simd_Approx_Recip:
		return ir.binary(function, .FDiv, one, value)
	case .Simd_Approx_Recip_Sqrt:
		return ir.binary(function, .FDiv, one, ir.unary(function, .FSqrt, value))
	}
	return simd_round_lane(function, kind, value, one)
}

// Adding and subtracting 2^23 (2^52) rounds a magnitude below it to the nearest integer, ties to even, in the current
// rounding mode. The other directions correct that result by one, and the sign is applied to the magnitude last so that
// results of zero keep the sign of the input. Magnitudes at or above the bound, infinities and NaNs are already integral.
@(private)
simd_round_lane :: proc(function: ^ir.Function, kind: check.Builtin_Kind, value, one: ir.Node_Id) -> ir.Node_Id {
	type := function.nodes.type[value]
	integer_type := float_bits_type(type)
	sign_mask := i64(min(i32)) if integer_type == .I32 else min(i64)
	bits := ir.convert(function, .Bitcast, value, integer_type)
	sign := ir.binary(function, .And, bits, ir.const_int(function, integer_type, sign_mask))
	magnitude := ir.convert(function, .Bitcast, ir.binary(function, .Xor, bits, sign), type)
	bound := ir.const_float(function, type, 0x4B000000 if type == .F32 else 0x4330000000000000)
	nearest := ir.binary(function, .FSub, ir.binary(function, .FAdd, magnitude, bound), bound)
	floor := ir.select(function, ir.compare(function, .FLt, magnitude, nearest), ir.binary(function, .FSub, nearest, one), nearest)
	ceil := ir.select(function, ir.compare(function, .FLt, nearest, magnitude), ir.binary(function, .FAdd, nearest, one), nearest)
	negative := ir.compare(function, .Ne, sign, ir.const_int(function, integer_type, 0))
	rounded: ir.Node_Id
	#partial switch kind {
	case .Simd_Nearest:
		rounded = nearest
	case .Simd_Trunc:
		rounded = floor
	case .Simd_Floor:
		rounded = ir.select(function, negative, ceil, floor)
	case:
		rounded = ir.select(function, negative, floor, ceil)
	}
	signed := ir.convert(function, .Bitcast, ir.binary(function, .Or, ir.convert(function, .Bitcast, rounded, integer_type), sign), type)
	return ir.select(function, ir.compare(function, .FLt, magnitude, bound), signed, value)
}

@(private)
Lane_Guard :: struct {
	branch: ir.Branch_Point,
	end:    ir.Jump_Target_Id,
}

// Opens the arm taken when `condition` holds; memory accessed inside it is untouched otherwise.
@(private)
lane_guard_begin :: proc(state: ^Procedure_State, condition: ir.Node_Id) -> Lane_Guard {
	builder := state.builder
	guard := Lane_Guard {
		end = ir.jump_target_make(builder),
	}
	guard.branch = ir.branch_if(builder, condition)
	ir.enter_arm(builder, guard.branch, 0)
	return guard
}

@(private)
lane_guard_end :: proc(state: ^Procedure_State, guard: Lane_Guard) {
	builder := state.builder
	ir.jump_to(builder, guard.end)
	ir.enter_arm(builder, guard.branch, 1)
	ir.jump_to(builder, guard.end)
	ir.seal_target(builder, guard.end)
}

// A mask lane selects its element when its lowest bit is set, as the official backend truncates the mask to one bit.
@(private)
simd_mask_lane :: proc(state: ^Procedure_State, mask: ir.Node_Id, lane: i64, mask_elem: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	value := simd_lane_value(state, mask, lane, mask_elem)
	if function.nodes.type[value] == .Bool { return value }
	type := function.nodes.type[value]
	return ir.compare(function, .Ne, ir.binary(function, .And, value, ir.const_int(function, type, 1)), ir.const_int(function, type, 0))
}

// Every lane starts as the pass-through vector; the lanes whose mask is set are replaced from memory. `values` are
// the pointer (a vector of pointers for a gather), the pass-through vector and the mask.
@(private)
lower_simd_masked_load :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	type, mask_type: types.Type_Id,
	kind: check.Builtin_Kind,
	values: []ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, type)
	mask_elem, mask_lanes := simd_shape(state, mask_type)
	if mask_lanes != lanes || !simd_mask_type_valid(state, mask_elem) { return lower_fail(state, node, .Builtin) }
	size := state.job.layouts[elem].size
	address := simd_slot(state, type)
	lower_store(state, address, values[1], type)
	if function.error != nil { return 0 }
	filled := ir.const_int(function, .I64, 0)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		taken := simd_mask_lane(state, values[2], lane, mask_elem)
		guard := lane_guard_begin(state, taken)
		source: ir.Node_Id
		#partial switch kind {
		case .Simd_Gather:
			source = lower_simd_gather_pointer(state, values[0], lane)
		case .Simd_Masked_Load:
			source = ir.ptr_offset(function, values[0], lane * size)
		case:
			source = ir.ptr_index(function, values[0], filled, u32(size))
		}
		lower_store(state, simd_lane_address(state, address, lane, elem), lower_load(state, source, elem), elem)
		lane_guard_end(state, guard)
		if kind == .Simd_Masked_Expand_Load { filled = simd_advance_packed_index(function, filled, taken) }
	}
	return address
}

@(private)
lower_simd_gather_pointer :: proc(state: ^Procedure_State, pointers: ir.Node_Id, lane: i64) -> ir.Node_Id {
	return lower_load_word(state, ir.ptr_offset(state.job.function, pointers, lane * 8), .Ptr)
}

@(private)
simd_advance_packed_index :: proc(function: ^ir.Function, index, taken: ir.Node_Id) -> ir.Node_Id {
	return ir.binary(function, .Add, index, ir.convert(function, .Zext, taken, .I64))
}

@(private)
simd_mask_type_valid :: proc(state: ^Procedure_State, mask_elem: types.Type_Id) -> bool {
	scalar := scalar_type(state, mask_elem)
	return scalar == .Bool || is_integer_type(scalar)
}

// `values` are the pointer (a vector of pointers for a scatter), the vector to store and the mask.
@(private)
lower_simd_masked_store :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan, kind: check.Builtin_Kind) {
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return }
	if len(plan.arguments) != 3 { lower_fail(state, node, .Builtin); return }
	function := state.job.function
	elem, lanes := simd_shape(state, operand_type(state, plan.arguments[1]))
	mask_elem, mask_lanes := simd_shape(state, operand_type(state, plan.arguments[2]))
	if mask_lanes != lanes || !simd_mask_type_valid(state, mask_elem) { lower_fail(state, node, .Builtin); return }
	size := state.job.layouts[elem].size
	filled := ir.const_int(function, .I64, 0)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return }
		taken := simd_mask_lane(state, values[2], lane, mask_elem)
		guard := lane_guard_begin(state, taken)
		destination: ir.Node_Id
		#partial switch kind {
		case .Simd_Scatter:
			destination = lower_simd_gather_pointer(state, values[0], lane)
		case .Simd_Masked_Store:
			destination = ir.ptr_offset(function, values[0], lane * size)
		case:
			destination = ir.ptr_index(function, values[0], filled, u32(size))
		}
		lower_store(state, destination, simd_lane_value(state, values[1], lane, elem), elem)
		lane_guard_end(state, guard)
		if kind == .Simd_Masked_Compress_Store { filled = simd_advance_packed_index(function, filled, taken) }
	}
}

// `add_bisect` and `mul_bisect` combine the low half with the high half, `pairs` combine neighbours, and each halves
// the lane count until one remains; `ordered` folds left to right, starting from the identity for floats.
@(private)
lower_simd_reduce_arithmetic :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	kind: check.Builtin_Kind,
	vector_type: types.Type_Id,
	vector: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	elem, lanes := simd_shape(state, vector_type)
	lane_type := scalar_type(state, elem)
	floating := lower_type(state, elem).kind == .Float
	half := is_float16(state, elem)
	if lanes < 1 || !(floating || is_integer_type(lane_type)) { return lower_fail(state, node, .Builtin) }
	multiply := kind == .Simd_Reduce_Mul_Bisect || kind == .Simd_Reduce_Mul_Ordered || kind == .Simd_Reduce_Mul_Pairs
	remaining, allocation_error := make([]ir.Node_Id, lanes, virtual.arena_allocator(&function.arena))
	if allocation_error != nil {
		function.error = allocation_error
		return 0
	}
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		remaining[lane] = simd_lane_value(state, vector, lane, elem)
	}
	combine := proc(function: ^ir.Function, multiply, floating, half: bool, left, right: ir.Node_Id) -> ir.Node_Id {
		if half {
			result, _ := lower_float16_operation(function, .Mul if multiply else .Add, left, right)
			return result
		}
		return ir.binary(function, simd_arithmetic_kind(.Simd_Mul if multiply else .Simd_Add, floating), left, right)
	}
	if kind == .Simd_Reduce_Add_Ordered || kind == .Simd_Reduce_Mul_Ordered {
		accumulator := remaining[0]
		if floating {
			identity: ir.Node_Id
			if half {
				identity = ir.const_int(function, .I16, 0x3C00 if multiply else 0)
			} else {
				identity = simd_float_one(function, lane_type) if multiply else ir.const_float(function, lane_type, 0)
			}
			accumulator = combine(function, multiply, floating, half, identity, remaining[0])
		}
		for lane in 1 ..< int(lanes) {
			accumulator = combine(function, multiply, floating, half, accumulator, remaining[lane])
		}
		return accumulator
	}
	pairs := kind == .Simd_Reduce_Add_Pairs || kind == .Simd_Reduce_Mul_Pairs
	count := int(lanes)
	for count > 1 {
		count /= 2
		for index in 0 ..< count {
			left, right := index, index + count
			if pairs { left, right = 2 * index, 2 * index + 1 }
			remaining[index] = combine(function, multiply, floating, half, remaining[left], remaining[right])
		}
	}
	return remaining[0]
}

@(private)
simd_float_one :: proc(function: ^ir.Function, type: ir.Value_Type) -> ir.Node_Id {
	return ir.const_float(function, type, 0x3F800000 if type == .F32 else 0x3FF0000000000000)
}
