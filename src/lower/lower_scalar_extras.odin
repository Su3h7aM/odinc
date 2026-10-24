package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Longest chain of saved frame pointers `return_address` and `frame_address` unroll.
MAX_FRAME_WALK :: 64

@(private)
is_scalar_extra :: proc(kind: check.Builtin_Kind) -> bool {
	#partial switch kind {
	case .Fused_Mul_Add,
	     .Fixed_Point_Mul,
	     .Fixed_Point_Div,
	     .Fixed_Point_Mul_Sat,
	     .Fixed_Point_Div_Sat,
	     .Prefetch_Read_Instruction,
	     .Prefetch_Read_Data,
	     .Prefetch_Write_Instruction,
	     .Prefetch_Write_Data,
	     .Return_Address,
	     .Frame_Address,
	     .Stack_Pointer,
	     .Address_Of_Return_Address:
		return true
	}
	return false
}

@(private)
lower_scalar_extra :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return 0 }
	#partial switch kind {
	case .Fused_Mul_Add:
		if len(values) != 3 { return lower_fail(state, node, .Builtin) }
		return lower_fused_mul_add(state, node, info.type, values)
	case .Fixed_Point_Mul, .Fixed_Point_Div, .Fixed_Point_Mul_Sat, .Fixed_Point_Div_Sat:
		if len(values) != 3 || state.job.function.nodes.kind[values[2]] != .Const_Int { return lower_fail(state, node, .Builtin) }
		return lower_fixed_point(state, node, info.type, kind, values)
	case .Prefetch_Read_Instruction, .Prefetch_Write_Instruction:
		// Without PREFETCHI the target has no instruction prefetch, and the operand has no effect to keep.
		return 0
	case .Prefetch_Read_Data, .Prefetch_Write_Data:
		return lower_data_prefetch(state, node, values)
	}
	return lower_frame_query(state, node, kind, values)
}

@(private)
lower_fused_mul_add :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id, values: []ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	descriptor := lower_type(state, type)
	if descriptor.kind != .Simd_Vector { return fused_multiply_add_lane(state, node, type, values[0], values[1], values[2]) }
	elem, lanes := simd_shape(state, type)
	address := simd_slot(state, type)
	for lane in 0 ..< lanes {
		if state.failed || function.error != nil { return 0 }
		result := fused_multiply_add_lane(
			state,
			node,
			elem,
			simd_lane_value(state, values[0], lane, elem),
			simd_lane_value(state, values[1], lane, elem),
			simd_lane_value(state, values[2], lane, elem),
		)
		lower_store(state, simd_lane_address(state, address, lane, elem), result, elem)
	}
	return address
}

// There is no FMA instruction in the x86-64 baseline, so the exact `a*b+c` is the runtime's software routine. A half
// float goes through the double routine and one rounding back.
@(private)
fused_multiply_add_lane :: proc(state: ^Procedure_State, node: syntax.Node_Index, elem: types.Type_Id, a, b, c: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	half := is_float16(state, elem)
	scalar := scalar_type(state, elem)
	if !half && !is_float_type(scalar) { return lower_fail(state, node, .Builtin) }
	operands := [3]ir.Node_Id{a, b, c}
	if half {
		for &operand in operands { operand = ir.convert(function, .Float_Ext, float16_widen(function, operand), .F64) }
	}
	name := "linux_math_fma_f32" if scalar == .F32 else "linux_math_fma_f64"
	declaration, found := lower_runtime_procedure(state, name)
	if !found { return lower_fail(state, node, .Builtin) }
	result := lower_runtime_scalar_call(state, declaration, operands[:])
	if half { return float16_narrow(function, result) }
	return result
}

// The product or quotient is computed in 128 bits, so no intermediate overflows. A product rounds toward negative
// infinity by the arithmetic shift; a signed quotient is truncated by the division and then corrected to match.
@(private)
lower_fixed_point :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	type: types.Type_Id,
	kind: check.Builtin_Kind,
	values: []ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	scalar := scalar_type(state, type)
	if !is_integer_type(scalar) || function.nodes.type[values[0]] != scalar || function.nodes.type[values[1]] != scalar {
		return lower_fail(state, node, .Builtin)
	}
	signed := signed_type(state, type)
	scale := ir.const_int(function, .I64, function.nodes.data[values[2]].int_value)
	left := fixed_point_widen(function, values[0], signed)
	right := fixed_point_widen(function, values[1], signed)
	is_division := kind == .Fixed_Point_Div || kind == .Fixed_Point_Div_Sat
	result: Wide_Words
	if is_division {
		numerator := wide_shift(function, .Shl, left, scale)
		result = wide_divide(state, .Quo, signed, numerator, right)
		zero := ir.const_int(function, .I64, 0)
		if signed {
			remainder := wide_sub(function, numerator, wide_mul(function, result, right))
			inexact := bool_not(function, wide_equal(function, remainder, Wide_Words{zero, zero}))
			opposite := ir.binary(function, .Xor, ir.compare(function, .SLt, numerator.high, zero), ir.compare(function, .SLt, right.high, zero))
			decrement := ir.convert(function, .Zext, ir.binary(function, .And, inexact, opposite), .I64)
			result = wide_sub(function, result, Wide_Words{decrement, zero})
		}
		result = fixed_point_division_by_zero(state, right, left, result)
	} else {
		result = wide_shift(function, .Sar if signed else .Shr, wide_mul(function, left, right), scale)
	}
	if kind == .Fixed_Point_Mul_Sat || kind == .Fixed_Point_Div_Sat { result = fixed_point_clamp(function, result, scalar, signed) }
	if scalar == .I64 { return result.low }
	return ir.convert(function, .Trunc, result.low, scalar)
}

@(private)
fixed_point_widen :: proc(function: ^ir.Function, value: ir.Node_Id, signed: bool) -> Wide_Words {
	low := value
	if function.nodes.type[value] != .I64 { low = ir.convert(function, .Sext if signed else .Zext, value, .I64) }
	high := ir.binary(function, .Sar, low, ir.const_int(function, .I64, 63)) if signed else ir.const_int(function, .I64, 0)
	return Wide_Words{low, high}
}

// A zero divisor traps by the file's policy inside the division; the other policies give 0, the dividend, or all ones.
@(private)
fixed_point_division_by_zero :: proc(state: ^Procedure_State, divisor, dividend, quotient: Wide_Words) -> Wide_Words {
	function := state.job.function
	mode := check.sources(state.job.program)[int(state.job.procedure.body.file) - 1].policy.division_by_zero
	if mode == .Trap { return quotient }
	zero := ir.const_int(function, .I64, 0)
	fallback := Wide_Words{zero, zero}
	#partial switch mode {
	case .Self:
		fallback = dividend
	case .All_Bits:
		fallback = Wide_Words{ir.const_int(function, .I64, -1), ir.const_int(function, .I64, -1)}
	}
	return wide_select(function, wide_equal(function, divisor, Wide_Words{zero, zero}), fallback, quotient)
}

@(private)
fixed_point_clamp :: proc(function: ^ir.Function, value: Wide_Words, scalar: ir.Value_Type, signed: bool) -> Wide_Words {
	bits := uint(scalar_bits(scalar))
	minimum, maximum: i64
	if signed {
		minimum = i64(u64(1) << (bits - 1))
		if bits < 64 { minimum = -minimum }
		maximum = ~minimum
		if bits < 64 { maximum = i64((u64(1) << (bits - 1)) - 1) }
	} else {
		maximum = i64(max(u64) >> (64 - bits))
	}
	zero := ir.const_int(function, .I64, 0)
	lowest := Wide_Words{ir.const_int(function, .I64, minimum), ir.const_int(function, .I64, -1 if minimum < 0 else 0)}
	highest := Wide_Words{ir.const_int(function, .I64, maximum), zero}
	result := wide_select(function, wide_less(function, value, lowest, signed), lowest, value)
	return wide_select(function, wide_less(function, highest, result, signed), highest, result)
}

// The locality 0..3 is the number of levels to keep the line in: 3 is T0, 2 is T1, 1 is T2 and 0 is the non-temporal
// hint. The write forms use the same instructions, as the baseline has no PREFETCHW.
@(private)
lower_data_prefetch :: proc(state: ^Procedure_State, node: syntax.Node_Index, values: []ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	if len(values) != 2 || function.nodes.type[values[0]] != .Ptr || function.nodes.kind[values[1]] != .Const_Int { return lower_fail(state, node, .Builtin) }
	operation: ir.Target_Op
	switch function.nodes.data[values[1]].int_value {
	case 0:
		operation = .Prefetch_Nta
	case 1:
		operation = .Prefetch_T2
	case 2:
		operation = .Prefetch_T1
	case 3:
		operation = .Prefetch_T0
	case:
		return lower_fail(state, node, .Builtin)
	}
	lower_target_op(state, node, operation, {values[0]}, nil)
	return 0
}

// Every frame of this backend is `push rbp; mov rbp, rsp`, so the saved frame pointer chain is the call chain: the
// return address of a frame is the word above its saved `rbp`.
@(private)
lower_frame_query :: proc(state: ^Procedure_State, node: syntax.Node_Index, kind: check.Builtin_Kind, values: []ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	results: [1]ir.Node_Id
	if kind == .Stack_Pointer {
		lower_target_op(state, node, .Stack_Pointer, nil, results[:])
		return results[0]
	}
	lower_target_op(state, node, .Frame_Pointer, nil, results[:])
	frame := results[0]
	level := i64(0)
	if len(values) == 1 {
		if function.nodes.kind[values[0]] != .Const_Int { return lower_fail(state, node, .Builtin) }
		level = function.nodes.data[values[0]].int_value
	}
	if level < 0 || level > MAX_FRAME_WALK { return lower_fail(state, node, .Builtin) }
	for _ in 0 ..< level { frame = lower_load_word(state, frame, .Ptr) }
	if kind == .Frame_Address { return frame }
	address := ir.ptr_offset(function, frame, 8)
	if kind == .Address_Of_Return_Address { return address }
	return lower_load_word(state, address, .Ptr)
}
