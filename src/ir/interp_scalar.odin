package ir

import "core:math/bits"

// Values are canonical `u64` patterns: zero-extended from the width of their type, `Bool` as bit 0,
// floats as their IEEE bits.

interp_width :: proc(type: Value_Type) -> int {
	#partial switch type {
	case .Bool:
		return 1
	case .I8:
		return 8
	case .I16, .F16:
		return 16
	case .I32, .F32:
		return 32
	case .I64, .F64, .Ptr:
		return 64
	}
	return 0
}

interp_canonical :: proc(type: Value_Type, value: u64) -> u64 {
	width := interp_width(type)
	if width == 0 || width >= 64 {
		return value
	}
	return value & (u64(1) << u64(width) - 1)
}

interp_sign_extend :: proc(value: u64, width: int) -> i64 {
	if width >= 64 || width == 0 {
		return i64(value)
	}
	shift := u64(64 - width)
	return i64(value << shift) >> shift
}

interp_sign_bit :: proc(type: Value_Type) -> u64 {
	return u64(1) << u64(interp_width(type) - 1)
}

interp_operand :: proc(s: ^Interp_State, id: Node_Id, slot: int) -> (u64, bool) {
	return interp_evaluate(s, node_input(s.fn, id, slot))
}

interp_operand_width :: proc(s: ^Interp_State, id: Node_Id, slot: int) -> int {
	return interp_width(s.fn.nodes.type[node_input(s.fn, id, slot)])
}

// Computes one pure node or projection. Pinned nodes never reach here.
interp_compute :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	fn := s.fn
	type := fn.nodes.type[id]
	#partial switch fn.nodes.kind[id] {
	case .Const_Int:
		return interp_canonical(type, u64(fn.nodes.data[id].int_value)), true
	case .Const_Float:
		return interp_canonical(type, fn.nodes.data[id].float_bits), true
	case .Undef:
		return 0, true
	case .Stack_Slot, .Symbol_Addr, .Tls_Addr:
		return interp_address(s, id)
	case .Proj:
		return interp_projection(s, id)
	case .Select:
		condition := interp_operand(s, id, 0) or_return
		return interp_operand(s, id, 1 if condition & 1 == 1 else 2)
	case .Add, .Sub, .Mul, .And, .Or, .Xor:
		a := interp_operand(s, id, 0) or_return
		b := interp_operand(s, id, 1) or_return
		return interp_integer_arithmetic(fn.nodes.kind[id], type, a, b), true
	case .Shl, .Shr, .Sar:
		return interp_shift(s, id)
	case .Eq, .Ne, .SLt, .SLe, .ULt, .ULe:
		return interp_integer_compare(s, id)
	case .Trunc, .Zext, .Bitcast:
		a := interp_operand(s, id, 0) or_return
		return interp_canonical(type, a), true
	case .Sext:
		a := interp_operand(s, id, 0) or_return
		return interp_canonical(type, u64(interp_sign_extend(a, interp_operand_width(s, id, 0)))), true
	case .Popcnt:
		a := interp_operand(s, id, 0) or_return
		return u64(bits.count_ones(a)), true
	case .Clz:
		a := interp_operand(s, id, 0) or_return
		width := interp_width(type)
		if a == 0 {
			return u64(width), true
		}
		return u64(bits.leading_zeros(a)) - u64(64 - width), true
	case .Ctz:
		a := interp_operand(s, id, 0) or_return
		if a == 0 {
			return u64(interp_width(type)), true
		}
		return u64(bits.trailing_zeros(a)), true
	case .Bswap:
		a := interp_operand(s, id, 0) or_return
		switch interp_width(type) {
		case 8:
			return a, true
		case 16:
			return u64(bits.byte_swap(u16(a))), true
		case 32:
			return u64(bits.byte_swap(u32(a))), true
		}
		return bits.byte_swap(a), true
	case .Mul_Hi_U:
		a := interp_operand(s, id, 0) or_return
		b := interp_operand(s, id, 1) or_return
		high, _ := bits.mul_u64(a, b)
		return high, true
	case .Mul_Hi_S:
		a := interp_operand(s, id, 0) or_return
		b := interp_operand(s, id, 1) or_return
		high, _ := bits.mul_u64(a, b)
		if i64(a) < 0 {
			high -= b
		}
		if i64(b) < 0 {
			high -= a
		}
		return high, true
	case .Ptr_Offset:
		base := interp_operand(s, id, 0) or_return
		return base + u64(fn.nodes.data[id].int_value), true
	case .Ptr_Index:
		base := interp_operand(s, id, 0) or_return
		index := interp_operand(s, id, 1) or_return
		return base + index * u64(fn.nodes.data[id].index), true
	case .Sint_To_Float,
	     .Uint_To_Float,
	     .Float_To_Sint,
	     .Float_To_Uint,
	     .Float_Ext,
	     .Float_Trunc,
	     .FEq,
	     .FLt,
	     .FLe,
	     .FNe,
	     .FAdd,
	     .FSub,
	     .FMul,
	     .FDiv,
	     .FNeg,
	     .FSqrt:
		return interp_float_compute(s, id)
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}

// `Proj` of `Start`: index 1 is the memory token, index 2.. the parameters. Other projections are unsupported.
@(private = "file")
interp_projection :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	source := node_input(s.fn, id, 0)
	index := s.fn.nodes.data[id].index
	if s.fn.nodes.kind[source] == .Load_Ordered || s.fn.nodes.kind[source] == .Call || s.fn.nodes.kind[source] == .Syscall {
		if index == 0 {
			return 0, true
		}
		return interp_evaluate(s, source)
	}
	if s.fn.nodes.kind[source] == .Start {
		switch {
		case index == 1:
			return 0, true
		case index >= 2 && int(index - 2) < len(s.arguments):
			return interp_canonical(s.fn.nodes.type[id], s.arguments[index - 2]), true
		}
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}

@(private = "file")
interp_integer_arithmetic :: proc(kind: Node_Kind, type: Value_Type, a, b: u64) -> u64 {
	#partial switch kind {
	case .Add:
		return interp_canonical(type, a + b)
	case .Sub:
		return interp_canonical(type, a - b)
	case .Mul:
		return interp_canonical(type, a * b)
	case .And:
		return a & b
	case .Or:
		return a | b
	}
	return a ~ b
}

// The count is unsigned in its own width; a count at or above the width of `a` gives 0, or sign fill for `Sar`.
@(private = "file")
interp_shift :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	type := s.fn.nodes.type[id]
	width := u64(interp_width(type))
	a := interp_operand(s, id, 0) or_return
	count := interp_operand(s, id, 1) or_return
	#partial switch s.fn.nodes.kind[id] {
	case .Shl:
		if count >= width {
			return 0, true
		}
		return interp_canonical(type, a << count), true
	case .Shr:
		if count >= width {
			return 0, true
		}
		return a >> count, true
	}
	signed := interp_sign_extend(a, int(width))
	if count >= width {
		if signed < 0 {
			return interp_canonical(type, ~u64(0)), true
		}
		return 0, true
	}
	return interp_canonical(type, u64(signed >> count)), true
}

interp_divide :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	type := s.fn.nodes.type[id]
	width := interp_width(type)
	a := interp_operand(s, id, 1) or_return
	b := interp_operand(s, id, 2) or_return
	if b == 0 {
		interp_fail(s, .Arith_Trap, id)
		return 0, false
	}
	#partial switch s.fn.nodes.kind[id] {
	case .UDiv:
		return a / b, true
	case .URem:
		return a % b, true
	}
	dividend := interp_sign_extend(a, width)
	divisor := interp_sign_extend(b, width)
	if divisor == -1 && dividend == interp_sign_extend(interp_sign_bit(type), width) {
		interp_fail(s, .Arith_Trap, id)
		return 0, false
	}
	if s.fn.nodes.kind[id] == .SRem {
		return interp_canonical(type, u64(dividend % divisor)), true
	}
	return interp_canonical(type, u64(dividend / divisor)), true
}

@(private = "file")
interp_integer_compare :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	a := interp_operand(s, id, 0) or_return
	b := interp_operand(s, id, 1) or_return
	width := interp_operand_width(s, id, 0)
	result: bool
	#partial switch s.fn.nodes.kind[id] {
	case .Eq:
		result = a == b
	case .Ne:
		result = a != b
	case .SLt:
		result = interp_sign_extend(a, width) < interp_sign_extend(b, width)
	case .SLe:
		result = interp_sign_extend(a, width) <= interp_sign_extend(b, width)
	case .ULt:
		result = a < b
	case .ULe:
		result = a <= b
	}
	return u64(result), true
}
