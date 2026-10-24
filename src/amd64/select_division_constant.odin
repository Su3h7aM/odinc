package amd64

import "core:math/bits"
import x86 "core:rexcode/isa/x86"
import "oc:ir"

// Division by a constant without DIV/IDIV. Unsigned: Granlund & Montgomery 1994, Theorem 4.2 (shift form)
// and Figure 4.1 (add form). Signed: Figure 5.2. Powers of two use shifts. Divisors 0, 1 and -1 keep the
// generic path, which owns the divide-by-zero and INT_MIN / -1 traps.

@(private)
Unsigned_Division_Magic :: struct {
	multiplier: u64,
	shift:      u32,
	add:        bool,
}

@(private)
Signed_Division_Magic :: struct {
	multiplier: i64,
	shift:      u32,
}

@(private)
ceil_log2 :: proc(value: u128) -> u32 {
	log: u32
	for u128(1) << log < value { log += 1 }
	return log
}

// The multiplier is pre-aligned so the high 64 bits of `x * multiplier` give `floor(x * m / 2^(64 - ...))`
// as described at `multiply_high_constant`.
@(private)
unsigned_division_magic :: proc(width_bits: u32, divisor: u64) -> Unsigned_Division_Magic {
	wide := u128(divisor)
	log := ceil_log2(wide)
	for shift in 0 ..< log {
		total := width_bits + shift
		multiplier := ((u128(1) << total) + wide - 1) / wide
		excess := multiplier * wide - (u128(1) << total)
		if excess <= u128(1) << shift {
			high_bits := min(total, 64)
			return {multiplier = u64(multiplier) << (64 - high_bits), shift = total - high_bits}
		}
	}
	multiplier := (u128(1) << width_bits) * ((u128(1) << log) - wide) / wide + 1
	return {multiplier = u64(multiplier) << (64 - width_bits), shift = log - 1, add = true}
}

@(private)
signed_division_magic :: proc(width_bits: u32, divisor: i64) -> Signed_Division_Magic {
	magnitude := u128(abs(i128(divisor)))
	log := ceil_log2(magnitude)
	multiplier := 1 + (u128(1) << (width_bits + log - 1)) / magnitude
	high := i128(multiplier) - (i128(1) << width_bits)
	return {multiplier = i64(high) * (i64(1) << (64 - width_bits)), shift = log - 1}
}

// The divisor operand of a division, sign- or zero-extended from its width, when it is a constant
// the constant path can handle.
@(private)
constant_divisor :: proc(selector: ^Selector, node: ir.Node_Id) -> (divisor: i64, ok: bool) {
	input := selector.input
	divisor_node := ir.node_input(input, node, 2)
	if input.nodes.kind[divisor_node] != .Const_Int { return 0, false }
	kind := input.nodes.kind[node]
	signed := kind == .SDiv || kind == .SRem
	shift := 64 - u32(select_width(input.nodes.type[node])) * 8
	normalized := u64(input.nodes.data[divisor_node].int_value) << shift
	if signed {
		divisor = i64(normalized) >> shift
		return divisor, divisor != 0 && divisor != 1 && divisor != -1
	}
	divisor = i64(normalized >> shift)
	return divisor, u64(divisor) >= 2
}

@(private)
select_extended_64 :: proc(selector: ^Selector, node: ir.Node_Id, signed: bool) -> (value: Vreg, err: Select_Status) {
	value = select_value(selector, node) or_return
	width := select_width(selector.input.nodes.type[node])
	if width == 8 { return }
	extended := new_vreg(selector.output, .Int) or_return
	if !signed {
		if width < 4 {
			emit(selector.output, selector.block, .MOVZX, width, extended, value) or_return
		} else {
			emit(selector.output, selector.block, .MOV, 4, extended, value) or_return
		}
	} else {
		source := value
		if width < 4 {
			source = new_vreg(selector.output, .Int) or_return
			emit(selector.output, selector.block, .MOVSX, width, source, value) or_return
		}
		emit(selector.output, selector.block, .MOVSXD, 8, extended, source) or_return
	}
	value = extended
	return
}

@(private)
shift_right_constant :: proc(selector: ^Selector, source: Vreg, count: u32) -> (shifted: Vreg, err: Select_Status) {
	if count == 0 { return source, nil }
	shifted = new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, .SHR, 8, shifted, source, Immediate(i64(count))) or_return
	return
}

// High 64 bits of `dividend * multiplier` (signed or unsigned), via the one-operand MUL/IMUL.
@(private)
multiply_high_constant :: proc(selector: ^Selector, dividend: Vreg, multiplier: u64, signed: bool) -> (high: Vreg, err: Select_Status) {
	output, block := selector.output, selector.block
	multiplicand := new_vreg(output, .Int) or_return
	emit_pseudo(output, block, .Copy, multiplicand, dividend) or_return
	factor := new_vreg(output, .Int) or_return
	emit(output, block, .MOVABS, 8, factor, Immediate(i64(multiplier))) or_return
	low := new_vreg(output, .Int) or_return
	high = new_vreg(output, .Int) or_return
	operands := [?]Machine_Operand{factor, fixed(multiplicand, gpr(.RAX), .Use), fixed(low, gpr(.RAX), .Def), fixed(high, gpr(.RDX), .Def)}
	emit_instruction(output, block, Machine_Instruction{mnemonic = .IMUL if signed else .MUL, width = 8, explicit_count = 1, operands = operands[:]}) or_return
	return
}

@(private)
select_unsigned_quotient :: proc(selector: ^Selector, dividend: Vreg, width_bits: u32, divisor: u64) -> (quotient: Vreg, err: Select_Status) {
	if divisor & (divisor - 1) == 0 {
		shift := u32(bits.trailing_zeros(divisor))
		quotient = new_vreg(selector.output, .Int) or_return
		emit(selector.output, selector.block, .SHR, 8, quotient, dividend, Immediate(i64(shift))) or_return
		return
	}
	magic := unsigned_division_magic(width_bits, divisor)
	high := multiply_high_constant(selector, dividend, magic.multiplier, false) or_return
	if !magic.add { return shift_right_constant(selector, high, magic.shift) }
	difference := new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, .SUB, 8, difference, dividend, high) or_return
	half := new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, .SHR, 8, half, difference, Immediate(1)) or_return
	sum := new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, .ADD, 8, sum, high, half) or_return
	return shift_right_constant(selector, sum, magic.shift)
}

@(private)
select_signed_quotient :: proc(selector: ^Selector, dividend: Vreg, width_bits: u32, divisor: i64) -> (quotient: Vreg, err: Select_Status) {
	output, block := selector.output, selector.block
	sign := new_vreg(output, .Int) or_return
	emit(output, block, .SAR, 8, sign, dividend, Immediate(63)) or_return
	magnitude := u64(divisor)
	if divisor < 0 { magnitude = -u64(divisor) }
	if magnitude & (magnitude - 1) == 0 {
		shift := u32(bits.trailing_zeros(magnitude))
		bias := new_vreg(output, .Int) or_return
		emit(output, block, .SHR, 8, bias, sign, Immediate(i64(64 - shift))) or_return
		adjusted := new_vreg(output, .Int) or_return
		emit(output, block, .ADD, 8, adjusted, dividend, bias) or_return
		quotient = new_vreg(output, .Int) or_return
		emit(output, block, .SAR, 8, quotient, adjusted, Immediate(i64(shift))) or_return
	} else {
		magic := signed_division_magic(width_bits, divisor)
		high := multiply_high_constant(selector, dividend, u64(magic.multiplier), true) or_return
		sum := new_vreg(output, .Int) or_return
		emit(output, block, .ADD, 8, sum, dividend, high) or_return
		shifted := new_vreg(output, .Int) or_return
		emit(output, block, .SAR, 8, shifted, sum, Immediate(i64(magic.shift))) or_return
		quotient = new_vreg(output, .Int) or_return
		emit(output, block, .SUB, 8, quotient, shifted, sign) or_return
	}
	if divisor < 0 {
		negated := new_vreg(output, .Int) or_return
		emit(output, block, .NEG, 8, negated, quotient) or_return
		quotient = negated
	}
	return
}

@(private)
select_division_by_constant :: proc(selector: ^Selector, node: ir.Node_Id, divisor: i64) -> Select_Status {
	input, output := selector.input, selector.output
	kind := input.nodes.kind[node]
	signed := kind == .SDiv || kind == .SRem
	width_bits := u32(select_width(input.nodes.type[node])) * 8
	dividend := select_extended_64(selector, ir.node_input(input, node, 1), signed) or_return
	quotient: Vreg
	if signed {
		quotient = select_signed_quotient(selector, dividend, width_bits, divisor) or_return
	} else {
		quotient = select_unsigned_quotient(selector, dividend, width_bits, u64(divisor)) or_return
	}
	if kind != .SRem && kind != .URem {
		return emit_pseudo(output, selector.block, .Copy, selector.values[node], quotient)
	}
	divisor_register := new_vreg(output, .Int) or_return
	mnemonic: x86.Mnemonic = .MOV
	if divisor < i64(min(i32)) || divisor > i64(max(i32)) { mnemonic = .MOVABS }
	emit(output, selector.block, mnemonic, 8, divisor_register, Immediate(divisor)) or_return
	product := new_vreg(output, .Int) or_return
	emit(output, selector.block, .IMUL, 8, product, quotient, divisor_register) or_return
	remainder := new_vreg(output, .Int) or_return
	emit(output, selector.block, .SUB, 8, remainder, dividend, product) or_return
	return emit_pseudo(output, selector.block, .Copy, selector.values[node], remainder)
}
