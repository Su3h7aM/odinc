package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// Lane i of the result is table[indices[i] & (lanes - 1)], the official wrap of simd_runtime_swizzle.
// The wrapped indices never have a high bit, so a 16-lane byte swizzle is one PSHUFB over them.
@(private)
lower_simd_runtime_swizzle :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	if len(plan.arguments) != 2 { return lower_fail(state, node, .Builtin) }
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return 0 }
	function := state.job.function
	elem, lanes := simd_shape(state, info.type)
	layout := state.job.layouts[elem]
	elem_value := scalar_type(state, elem)
	if layout.error != .None || layout.size <= 0 || layout.size > i64(max(u32)) || elem_value == .None {
		return lower_fail(state, node, .Builtin)
	}
	wrapped := simd_slot(state, info.type)
	for lane in 0 ..< lanes {
		index := lower_load(state, simd_lane_address(state, values[1], lane, elem), elem)
		masked := ir.binary(function, .And, index, ir.const_int(function, elem_value, lanes - 1))
		lower_store(state, simd_lane_address(state, wrapped, lane, elem), masked, elem)
	}
	if lanes == 16 && layout.size == 1 {
		arguments := [2]ir.Node_Id{lower_load_word(state, values[0], .V128), lower_load_word(state, wrapped, .V128)}
		results: [1]ir.Node_Id
		if !lower_target_op(state, node, .Pshufb, arguments[:], results[:]) { return 0 }
		shuffled := simd_slot(state, info.type)
		lower_store_word(state, shuffled, results[0])
		return shuffled
	}
	result := simd_slot(state, info.type)
	for lane in 0 ..< lanes {
		index := lower_load(state, simd_lane_address(state, wrapped, lane, elem), elem)
		offset := index
		if elem_value != .I64 { offset = ir.convert(function, .Zext, index, .I64) }
		source := ir.ptr_index(function, values[0], offset, u32(layout.size))
		lower_store(state, simd_lane_address(state, result, lane, elem), lower_load(state, source, elem), elem)
	}
	return result
}
