package ir

import "core:math"

// Only `F32` and `F64` take part in float arithmetic here; `F16` is promoted by the builder (`Float_Ext`, op, `Float_Trunc`).
interp_is_float :: proc(type: Value_Type) -> bool {
	return type == .F32 || type == .F64
}

interp_float_to_f64 :: proc(type: Value_Type, bits_value: u64) -> f64 {
	if type == .F32 {
		return f64(transmute(f32)u32(bits_value))
	}
	return transmute(f64)bits_value
}

interp_f32_bits :: proc(value: f32) -> u64 {
	return u64(transmute(u32)value)
}

interp_float_compute :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	fn := s.fn
	type := fn.nodes.type[id]
	#partial switch fn.nodes.kind[id] {
	case .FEq, .FNe, .FLt, .FLe:
		return interp_float_compare(s, id)
	case .FAdd, .FSub, .FMul, .FDiv:
		a := interp_operand(s, id, 0) or_return
		b := interp_operand(s, id, 1) or_return
		return interp_float_arithmetic(s, id, a, b)
	case .FNeg:
		a := interp_operand(s, id, 0) or_return
		return a ~ interp_sign_bit(type), true
	case .FSqrt:
		a := interp_operand(s, id, 0) or_return
		if type == .F32 {
			return interp_f32_bits(math.sqrt(transmute(f32)u32(a))), true
		}
		if type == .F64 {
			return transmute(u64)math.sqrt(transmute(f64)a), true
		}
	case .Sint_To_Float, .Uint_To_Float:
		a := interp_operand(s, id, 0) or_return
		return interp_integer_to_float(s, id, a)
	case .Float_To_Sint, .Float_To_Uint:
		a := interp_operand(s, id, 0) or_return
		return interp_float_to_integer(s, id, a)
	case .Float_Ext, .Float_Trunc:
		a := interp_operand(s, id, 0) or_return
		source := fn.nodes.type[node_input(fn, id, 0)]
		if interp_is_float(source) && interp_is_float(type) {
			value := interp_float_to_f64(source, a)
			if type == .F32 {
				return interp_f32_bits(f32(value)), true
			}
			return transmute(u64)value, true
		}
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}

@(private = "file")
interp_float_compare :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	type := s.fn.nodes.type[node_input(s.fn, id, 0)]
	if !interp_is_float(type) {
		interp_fail(s, .Unsupported, id)
		return 0, false
	}
	a := interp_float_to_f64(type, interp_operand(s, id, 0) or_return)
	b := interp_float_to_f64(type, interp_operand(s, id, 1) or_return)
	result: bool
	#partial switch s.fn.nodes.kind[id] {
	case .FEq:
		result = a == b
	case .FNe:
		result = a != b
	case .FLt:
		result = a < b
	case .FLe:
		result = a <= b
	}
	return u64(result), true
}

@(private = "file")
interp_float_arithmetic :: proc(s: ^Interp_State, id: Node_Id, a, b: u64) -> (u64, bool) {
	type := s.fn.nodes.type[id]
	kind := s.fn.nodes.kind[id]
	if type == .F32 {
		x, y := transmute(f32)u32(a), transmute(f32)u32(b)
		#partial switch kind {
		case .FAdd:
			return interp_f32_bits(x + y), true
		case .FSub:
			return interp_f32_bits(x - y), true
		case .FMul:
			return interp_f32_bits(x * y), true
		case .FDiv:
			return interp_f32_bits(x / y), true
		}
	}
	if type == .F64 {
		x, y := transmute(f64)a, transmute(f64)b
		#partial switch kind {
		case .FAdd:
			return transmute(u64)(x + y), true
		case .FSub:
			return transmute(u64)(x - y), true
		case .FMul:
			return transmute(u64)(x * y), true
		case .FDiv:
			return transmute(u64)(x / y), true
		}
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}

@(private = "file")
interp_integer_to_float :: proc(s: ^Interp_State, id: Node_Id, a: u64) -> (u64, bool) {
	type := s.fn.nodes.type[id]
	signed := s.fn.nodes.kind[id] == .Sint_To_Float
	value: f64
	if signed {
		value = f64(interp_sign_extend(a, interp_operand_width(s, id, 0)))
	} else {
		value = f64(a)
	}
	#partial switch type {
	case .F32:
		if signed {
			return interp_f32_bits(f32(interp_sign_extend(a, interp_operand_width(s, id, 0)))), true
		}
		return interp_f32_bits(f32(a)), true
	case .F64:
		return transmute(u64)value, true
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}

// Out-of-range and NaN inputs are undefined (LLVM `fptosi`), so they report `Unsupported`.
@(private = "file")
interp_float_to_integer :: proc(s: ^Interp_State, id: Node_Id, a: u64) -> (u64, bool) {
	type := s.fn.nodes.type[id]
	source := s.fn.nodes.type[node_input(s.fn, id, 0)]
	if !interp_is_float(source) {
		interp_fail(s, .Unsupported, id)
		return 0, false
	}
	truncated := math.trunc(interp_float_to_f64(source, a))
	width := interp_width(type)
	if s.fn.nodes.kind[id] == .Float_To_Uint {
		if truncated >= 0 && truncated < math.pow(2, f64(width)) {
			return interp_canonical(type, u64(truncated)), true
		}
	} else {
		low := -math.pow(2, f64(width - 1))
		high := math.pow(2, f64(width - 1))
		if truncated >= low && truncated < high {
			return interp_canonical(type, u64(i64(truncated))), true
		}
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}
