package lower

import "oc:ir"
import "oc:syntax"
import "oc:types"

// `f16` operations widen both operands to `F32`, operate there, and round back to `F16`. For `+ - * /` and square
// root this equals one rounding, since 24 >= 2 * 11 + 2. Rounding is an integer sequence, so no runtime call is needed.
// An `f16` value is its 16 bits in an `I16` node. Operations widen both operands to `F32`, operate there, and round back.
// For `+ - * /` and square root this equals one rounding, since 24 >= 2 * 11 + 2. Rounding is an integer sequence, so no runtime call is needed.

@(private)
is_float16 :: proc(state: ^Procedure_State, id: types.Type_Id) -> bool {
	return lower_type(state, id).kind == .Float && state.job.layouts[id].size == 2
}

@(private)
F64_TWO_POW_28_BITS :: u64(0x41B0000000000000)

@(private)
F64_TWO_POW_MINUS_14_BITS :: u64(0x3F10000000000000)

@(private)
float16_widen :: proc(function: ^ir.Function, half: ir.Node_Id) -> ir.Node_Id {
	bits := ir.convert(function, .Zext, half, .I32)
	magnitude := ir.binary(function, .Shl, ir.binary(function, .And, bits, ir.const_int(function, .I32, 0x7fff)), ir.const_int(function, .I32, 13))
	// Multiplying by 2^112 renormalizes subnormal halves and is exact; infinities and NaNs take the select below.
	scaled_value := ir.binary(function, .FMul, ir.convert(function, .Bitcast, magnitude, .F32), ir.const_float(function, .F32, 0x77800000))
	special := ir.compare(function, .Eq, ir.binary(function, .And, bits, ir.const_int(function, .I32, 0x7c00)), ir.const_int(function, .I32, 0x7c00))
	magnitude_bits := ir.select(
		function,
		special,
		ir.binary(function, .Or, magnitude, ir.const_int(function, .I32, 0x7f800000)),
		ir.convert(function, .Bitcast, scaled_value, .I32),
	)
	sign := ir.binary(function, .Shl, ir.binary(function, .And, bits, ir.const_int(function, .I32, 0x8000)), ir.const_int(function, .I32, 16))
	return ir.convert(function, .Bitcast, ir.binary(function, .Or, magnitude_bits, sign), .F32)
}

// `wide` is `F64`; the result is the nearest `F16`, ties to even, with overflow to infinity.
@(private)
float16_narrow :: proc(function: ^ir.Function, wide: ir.Node_Id) -> ir.Node_Id {
	bits := ir.convert(function, .Bitcast, wide, .I64)
	magnitude := ir.binary(function, .And, bits, ir.const_int(function, .I64, 0x7fffffffffffffff))
	sign := ir.binary(function, .And, ir.binary(function, .Shr, bits, ir.const_int(function, .I64, 48)), ir.const_int(function, .I64, 0x8000))

	// Adding 2^28 leaves the rounded multiple of 2^-24 in the low mantissa bits of the sum.
	shifted := ir.binary(function, .FAdd, ir.convert(function, .Bitcast, magnitude, .F64), ir.const_float(function, .F64, F64_TWO_POW_28_BITS))
	subnormal := ir.binary(function, .Sub, ir.convert(function, .Bitcast, shifted, .I64), ir.const_int(function, .I64, i64(F64_TWO_POW_28_BITS)))

	// Rebias the exponent (1023 - 15) and round the 42 dropped bits to even.
	mantissa_lsb := ir.binary(function, .And, ir.binary(function, .Shr, magnitude, ir.const_int(function, .I64, 42)), ir.const_int(function, .I64, 1))
	rounded := ir.binary(function, .Add, magnitude, ir.binary(function, .Add, ir.const_int(function, .I64, 0x1ffffffffff), mantissa_lsb))
	normal := ir.binary(function, .Sub, ir.binary(function, .Shr, rounded, ir.const_int(function, .I64, 42)), ir.const_int(function, .I64, 0xfc000))

	is_nan := ir.compare(function, .ULt, ir.const_int(function, .I64, 0x7ff0000000000000), magnitude)
	quiet_mantissa := ir.binary(
		function,
		.Or,
		ir.binary(function, .And, ir.binary(function, .Shr, magnitude, ir.const_int(function, .I64, 42)), ir.const_int(function, .I64, 0x3ff)),
		ir.const_int(function, .I64, 0x200),
	)
	special := ir.binary(function, .Or, ir.const_int(function, .I64, 0x7c00), ir.select(function, is_nan, quiet_mantissa, ir.const_int(function, .I64, 0)))

	is_tiny := ir.compare(function, .ULt, magnitude, ir.const_int(function, .I64, i64(F64_TWO_POW_MINUS_14_BITS)))
	is_overflow := ir.compare(function, .ULe, ir.const_int(function, .I64, transmute(i64)f64(65520)), magnitude)
	half := ir.select(function, is_overflow, special, ir.select(function, is_tiny, subnormal, normal))
	return ir.convert(function, .Trunc, ir.binary(function, .Or, half, sign), .I16)
}

@(private)
float16_from_f32 :: proc(function: ^ir.Function, value: ir.Node_Id) -> ir.Node_Id {
	return float16_narrow(function, ir.convert(function, .Float_Ext, value, .F64))
}

@(private)
float16_negate :: proc(function: ^ir.Function, half: ir.Node_Id) -> ir.Node_Id {
	return ir.binary(function, .Xor, half, ir.const_int(function, .I16, -32768))
}

// Arithmetic results are `F16`; comparisons are `Bool`. `ok` is false for operators with no `f16` meaning.
@(private)
lower_float16_operation :: proc(function: ^ir.Function, operator: syntax.Token_Kind, left, right: ir.Node_Id) -> (result: ir.Node_Id, ok: bool) {
	wide_left := float16_widen(function, left)
	wide_right := float16_widen(function, right)
	#partial switch operator {
	case .Add:
		return float16_from_f32(function, ir.binary(function, .FAdd, wide_left, wide_right)), true
	case .Sub:
		return float16_from_f32(function, ir.binary(function, .FSub, wide_left, wide_right)), true
	case .Mul:
		return float16_from_f32(function, ir.binary(function, .FMul, wide_left, wide_right)), true
	case .Quo:
		return float16_from_f32(function, ir.binary(function, .FDiv, wide_left, wide_right)), true
	case .Cmp_Eq:
		return ir.compare(function, .FEq, wide_left, wide_right), true
	case .Not_Eq:
		return ir.compare(function, .FNe, wide_left, wide_right), true
	case .Lt:
		return ir.compare(function, .FLt, wide_left, wide_right), true
	case .Lt_Eq:
		return ir.compare(function, .FLe, wide_left, wide_right), true
	case .Gt:
		return ir.compare(function, .FLt, wide_right, wide_left), true
	case .Gt_Eq:
		return ir.compare(function, .FLe, wide_right, wide_left), true
	}
	return 0, false
}
