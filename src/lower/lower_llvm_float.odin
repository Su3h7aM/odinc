package lower

import "core:strings"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Llvm_Float_Rounding :: enum {
	Round,
	Nearest_Even,
}

@(private)
rounds_to_integer :: proc(operation: string) -> bool {
	return(
		strings.has_prefix(operation, "llvm.lround.") ||
		strings.has_prefix(operation, "llvm.llround.") ||
		strings.has_prefix(operation, "llvm.lrint.") ||
		strings.has_prefix(operation, "llvm.llrint.") \
	)
}

@(private)
float_constant :: proc(function: ^ir.Function, type: ir.Value_Type, value: f64) -> ir.Node_Id {
	if type == .F32 { return ir.const_float(function, type, u64(transmute(u32)f32(value))) }
	return ir.const_float(function, type, transmute(u64)f64(value))
}

// f16 operands (carried as `I16`) are computed in f32 and narrowed again, which is exact for rounding and ordering.
@(private)
llvm_float_rounding :: proc(function: ^ir.Function, rounding: Llvm_Float_Rounding, value: ir.Node_Id) -> (rounded: ir.Node_Id, ok: bool) {
	half := function.nodes.type[value] == .I16
	wide := float16_widen(function, value) if half else value
	type := function.nodes.type[wide]
	if !is_float_type(type) { return 0, false }
	switch rounding {
	case .Nearest_Even:
		rounded = simd_float_rounding_or_reciprocal(function, .Simd_Nearest, wide)
	case .Round:
		truncated := simd_float_rounding_or_reciprocal(function, .Simd_Trunc, wide)
		fraction := simd_float_sign_operation(function, .Simd_Abs, ir.binary(function, .FSub, wide, truncated))
		away := ir.binary(function, .FAdd, truncated, llvm_copysign(function, float_constant(function, type, 1), wide))
		rounded = ir.select(function, ir.compare(function, .FLt, fraction, float_constant(function, type, 0.5)), truncated, away)
	}
	if half { rounded = float16_from_f32(function, rounded) }
	return rounded, true
}

// `llvm.lround`, `llvm.llround`, `llvm.lrint` and `llvm.llrint`; the default rounding mode makes the `rint` forms round to even.
@(private)
lower_float_to_integer_rounding :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operation: string,
	result: types.Type_Id,
	value: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	target := scalar_type(state, result)
	if !is_integer_type(target) { return lower_fail(state, node, .Builtin) }
	rounding := Llvm_Float_Rounding.Round if strings.contains(operation, "round") else Llvm_Float_Rounding.Nearest_Even
	rounded, ok := llvm_float_rounding(function, rounding, value)
	if !ok { return lower_fail(state, node, .Builtin) }
	if function.nodes.type[rounded] == .I16 { rounded = float16_widen(function, rounded) }
	if rounding == .Round && target == .I32 {
		// The official backend calls the C `lround` and keeps the low 32 bits of its 64-bit result.
		return ir.convert(function, .Trunc, ir.convert(function, .Float_To_Sint, rounded, .I64), .I32)
	}
	return ir.convert(function, .Float_To_Sint, rounded, target)
}

// `llvm.minnum` family. A `num` form returns the other operand for a NaN, the others return the NaN; every form except
// `minnum` and `maxnum` on f32 and f64 orders -0.0 before +0.0 (the official backend does so for f16 too).
@(private)
llvm_float_extremum :: proc(function: ^ir.Function, operation: string, left, right: ir.Node_Id) -> (extremum: ir.Node_Id, ok: bool) {
	half := function.nodes.type[left] == .I16
	left, right := left, right
	if half { left, right = float16_widen(function, left), float16_widen(function, right) }
	type := function.nodes.type[left]
	if !is_float_type(type) || function.nodes.type[right] != type { return 0, false }
	minimum := strings.contains(operation, "min")
	chosen := ir.select(function, ir.compare(function, .FLt, left, right) if minimum else ir.compare(function, .FLt, right, left), left, right)
	if half || (operation != "llvm.minnum" && operation != "llvm.maxnum") {
		bits_type := float_bits_type(type)
		left_bits, right_bits := ir.convert(function, .Bitcast, left, bits_type), ir.convert(function, .Bitcast, right, bits_type)
		merged := ir.binary(function, .Or if minimum else .And, left_bits, right_bits)
		chosen = ir.select(function, ir.compare(function, .FEq, left, right), ir.convert(function, .Bitcast, merged, type), chosen)
	}
	propagates_nan := !strings.has_suffix(operation, "num")
	left_is_nan, right_is_nan := ir.compare(function, .FNe, left, left), ir.compare(function, .FNe, right, right)
	if propagates_nan {
		chosen = ir.select(function, right_is_nan, right, chosen)
		chosen = ir.select(function, left_is_nan, left, chosen)
	} else {
		chosen = ir.select(function, right_is_nan, left, chosen)
		chosen = ir.select(function, left_is_nan, right, chosen)
	}
	if half { chosen = float16_from_f32(function, chosen) }
	return chosen, true
}
