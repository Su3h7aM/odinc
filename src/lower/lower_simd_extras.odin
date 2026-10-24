package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Lane rearrangements and summaries of `#simd` values. Each result lane is a scalar copy or computation, as in `lower_simd.odin`.
@(private)
lower_simd_extra :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return 0 }
	function := state.job.function
	input_type := operand_type(state, plan.arguments[0])
	elem, lanes := simd_shape(state, input_type)
	if kind == .Simd_Extract_Lsbs { return lower_simd_extract_bits(state, node, info.type, input_type, values[0], false) }
	if kind == .Simd_To_Bits || kind == .Simd_To_Bits_Signed { return values[0] }
	floating := lower_type(state, elem).kind == .Float
	half := is_float16(state, elem)
	signed := signed_type(state, elem)
	if kind == .Simd_Reduce_Any || kind == .Simd_Reduce_All {
		combine := ir.Node_Kind.Or if kind == .Simd_Reduce_Any else ir.Node_Kind.And
		accumulator := simd_lane_value(state, values[0], 0, elem)
		for lane in 1 ..< lanes { accumulator = ir.binary(function, combine, accumulator, simd_lane_value(state, values[0], lane, elem)) }
		if function.nodes.type[accumulator] == .Bool { return accumulator }
		return ir.compare(function, .Ne, accumulator, ir.const_int(function, function.nodes.type[accumulator], 0))
	}
	if kind == .Simd_Sums_Of_N {
		count := function.nodes.data[values[1]].int_value
		return lower_simd_sums(state, info.type, values[0], elem, lanes, count)
	}
	if kind == .Simd_Interleave && len(values) == 1 { return values[0] }
	result_elem, result_lanes := simd_shape(state, info.type)
	if lower_type(state, info.type).kind != .Simd_Vector { return lower_fail(state, node, .Builtin) }
	address := simd_slot(state, info.type)
	for lane in 0 ..< result_lanes {
		if state.failed || function.error != nil { return 0 }
		result: ir.Node_Id
		#partial switch kind {
		case .Simd_Clamp:
			value := simd_lane_value(state, values[0], lane, elem)
			low := simd_lane_value(state, values[1], lane, elem)
			high := simd_lane_value(state, values[2], lane, elem)
			below, above: ir.Node_Id
			if floating {
				if half {
					below = ir.compare(function, .FLt, float16_widen(function, value), float16_widen(function, low))
				} else {
					below = ir.compare(function, .FLt, value, low)
				}
				value = ir.select(function, below, low, value)
				if half {
					above = ir.compare(function, .FLt, float16_widen(function, high), float16_widen(function, value))
				} else {
					above = ir.compare(function, .FLt, high, value)
				}
			} else {
				less := ir.Node_Kind.SLt if signed else ir.Node_Kind.ULt
				value = ir.select(function, ir.compare(function, less, value, low), low, value)
				above = ir.compare(function, less, high, value)
			}
			result = ir.select(function, above, high, value)
		case .Simd_Lanes_Reverse:
			result = simd_lane_value(state, values[0], lanes - 1 - lane, elem)
		case .Simd_Lanes_Rotate_Left, .Simd_Lanes_Rotate_Right:
			offset := function.nodes.data[values[1]].int_value
			if kind == .Simd_Lanes_Rotate_Right { offset = -offset }
			result = simd_lane_value(state, values[0], ((lane + offset) %% lanes + lanes) %% lanes, elem)
		case .Simd_Odd_Even:
			if lane < lanes / 2 {
				result = simd_lane_value(state, values[0], 2 * lane + 1, elem)
			} else {
				result = simd_lane_value(state, values[1], 2 * (lane - lanes / 2), elem)
			}
		case .Simd_Pairwise_Add, .Simd_Pairwise_Sub:
			left := simd_pair_lane(state, values, lane, 0, elem, lanes)
			right := simd_pair_lane(state, values, lane, 1, elem, lanes)
			add := kind == .Simd_Pairwise_Add
			switch {
			case half:
				result, _ = lower_float16_operation(function, .Add if add else .Sub, left, right)
			case floating:
				result = ir.binary(function, .FAdd if add else .FSub, left, right)
			case:
				result = ir.binary(function, .Add if add else .Sub, left, right)
			}
		case .Simd_Interleave:
			result = simd_lane_value(state, values[int(lane) %% len(values)], lane / i64(len(values)), elem)
		case:
			return lower_fail(state, node, .Builtin)
		}
		lower_store(state, simd_lane_address(state, address, lane, result_elem), result, result_elem)
	}
	return address
}

// Lane `2 * lane + side` of the two operands laid end to end.
@(private)
simd_pair_lane :: proc(state: ^Procedure_State, values: []ir.Node_Id, lane, side: i64, elem: types.Type_Id, lanes: i64) -> ir.Node_Id {
	index := 2 * lane + side
	if index < lanes { return simd_lane_value(state, values[0], index, elem) }
	return simd_lane_value(state, values[1], index - lanes, elem)
}

// Every group of `count` adjacent lanes adds up to one result lane, or the whole vector to a scalar. Floating sums start
// from +0.0 and add in lane order, except pairs, which add the two lanes directly.
@(private)
lower_simd_sums :: proc(state: ^Procedure_State, result_type: types.Type_Id, vector: ir.Node_Id, elem: types.Type_Id, lanes, count: i64) -> ir.Node_Id {
	function := state.job.function
	floating := lower_type(state, elem).kind == .Float
	half := is_float16(state, elem)
	groups := lanes / count
	address := ir.Node_Id(0)
	if groups > 1 { address = simd_slot(state, result_type) }
	total: ir.Node_Id
	for group in 0 ..< groups {
		if state.failed || function.error != nil { return 0 }
		first := group * count
		total = simd_lane_value(state, vector, first, elem)
		if floating && count != 2 {
			zero := ir.const_int(function, .I16, 0) if half else ir.const_float(function, scalar_type(state, elem), 0)
			total = simd_add_lanes(function, half, floating, zero, total)
		}
		for lane in first + 1 ..< first + count { total = simd_add_lanes(function, half, floating, total, simd_lane_value(state, vector, lane, elem)) }
		if groups > 1 { lower_store(state, simd_lane_address(state, address, group, elem), total, elem) }
	}
	if groups > 1 { return address }
	return total
}

@(private)
simd_add_lanes :: proc(function: ^ir.Function, half, floating: bool, left, right: ir.Node_Id) -> ir.Node_Id {
	if half {
		sum, _ := lower_float16_operation(function, .Add, left, right)
		return sum
	}
	return ir.binary(function, .FAdd if floating else .Add, left, right)
}

// Result `j` takes every n-th lane of the operand starting at lane `j`.
@(private)
lower_simd_deinterleave :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan, results: []ir.Node_Id) {
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return }
	function := state.job.function
	elem, lanes := simd_shape(state, operand_type(state, plan.arguments[0]))
	count := int(function.nodes.data[values[1]].int_value)
	if count != len(plan.results) || count > len(results) { lower_fail(state, node, .Builtin); return }
	for part in 0 ..< count {
		address := simd_slot(state, plan.results[part])
		for lane in 0 ..< lanes / i64(count) {
			if state.failed || function.error != nil { return }
			lower_store(state, simd_lane_address(state, address, lane, elem), simd_lane_value(state, values[0], lane * i64(count) + i64(part), elem), elem)
		}
		results[part] = address
	}
}
