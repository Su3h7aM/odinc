package amd64

import x86 "core:rexcode/isa/x86"
import "oc:ir"

// Baseline x86-64 has BSR, BSF and BSWAP but no LZCNT, TZCNT or POPCNT, so the counts use BSR, BSF
// and the bit-twiddling population count. Inputs are zero-extended to 64 bits first, which makes the
// 64-bit instructions correct for every width.
@(private)
select_bit_op :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	#partial switch selector.input.nodes.kind[node] {
	case .Clz:
		return select_count_leading_zeros(selector, node)
	case .Ctz:
		return select_count_trailing_zeros(selector, node)
	case .Popcnt:
		return select_population_count(selector, node)
	case .Bswap:
		return select_byte_swap(selector, node)
	}
	return select_failure(selector)
}

// Leading zeros are (width - 1) - bit_scan_reverse(value). A zero input selects 2 * width - 1 instead,
// because (width - 1) xor (2 * width - 1) is width; xor with width - 1 subtracts for every position.
@(private)
select_count_leading_zeros :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output, block := selector.input, selector.output, selector.block
	bits := i64(select_width(input.nodes.type[node])) * 8
	value := select_extended(selector, ir.node_input(input, node, 0), false) or_return
	position := new_vreg(output, .Int) or_return
	emit(output, block, .BSR, 8, position, value) or_return
	zero_position := new_vreg(output, .Int) or_return
	emit(output, block, .MOV, 4, zero_position, Immediate(2 * bits - 1)) or_return
	counted := new_vreg(output, .Int) or_return
	emit(output, block, .CMOVE, 8, counted, position, zero_position) or_return
	return emit(output, block, .XOR, 8, selector.values[node], counted, Immediate(bits - 1))
}

@(private)
select_count_trailing_zeros :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output, block := selector.input, selector.output, selector.block
	bits := i64(select_width(input.nodes.type[node])) * 8
	value := select_extended(selector, ir.node_input(input, node, 0), false) or_return
	position := new_vreg(output, .Int) or_return
	emit(output, block, .BSF, 8, position, value) or_return
	zero_count := new_vreg(output, .Int) or_return
	emit(output, block, .MOV, 4, zero_count, Immediate(bits)) or_return
	return emit(output, block, .CMOVE, 8, selector.values[node], position, zero_count)
}

// The SWAR population count: sums bits into pairs, nibbles and bytes, then multiplies the bytes together.
@(private)
select_population_count :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output, block := selector.input, selector.output, selector.block
	value := select_extended(selector, ir.node_input(input, node, 0), false) or_return
	pair_mask := select_bit_constant(selector, 0x5555555555555555) or_return
	half := select_bit_unary(selector, .SHR, value, 1) or_return
	half_bits := select_bit_binary(selector, .AND, half, pair_mask) or_return
	pairs := select_bit_binary(selector, .SUB, value, half_bits) or_return
	nibble_mask := select_bit_constant(selector, 0x3333333333333333) or_return
	low_pairs := select_bit_binary(selector, .AND, pairs, nibble_mask) or_return
	quarter := select_bit_unary(selector, .SHR, pairs, 2) or_return
	high_pairs := select_bit_binary(selector, .AND, quarter, nibble_mask) or_return
	nibbles := select_bit_binary(selector, .ADD, low_pairs, high_pairs) or_return
	byte_mask := select_bit_constant(selector, 0x0f0f0f0f0f0f0f0f) or_return
	shifted_nibbles := select_bit_unary(selector, .SHR, nibbles, 4) or_return
	nibble_sums := select_bit_binary(selector, .ADD, nibbles, shifted_nibbles) or_return
	bytes := select_bit_binary(selector, .AND, nibble_sums, byte_mask) or_return
	ones_per_byte := select_bit_constant(selector, 0x0101010101010101) or_return
	summed := new_vreg(output, .Int) or_return
	emit(output, block, .IMUL, 8, summed, bytes, ones_per_byte) or_return
	return emit(output, block, .SHR, 8, selector.values[node], summed, Immediate(56))
}

@(private)
select_byte_swap :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output, block := selector.input, selector.output, selector.block
	width := select_width(input.nodes.type[node])
	value := select_extended(selector, ir.node_input(input, node, 0), false) or_return
	if width == 1 { return emit_pseudo(output, block, .Copy, selector.values[node], value) }
	swapped := new_vreg(output, .Int) or_return
	if width == 2 {
		emit(output, block, .BSWAP, 4, swapped, value) or_return
		return emit(output, block, .SHR, 4, selector.values[node], swapped, Immediate(16))
	}
	return emit(output, block, .BSWAP, width, selector.values[node], value)
}

@(private)
select_bit_constant :: proc(selector: ^Selector, constant: i64) -> (register: Vreg, err: Select_Status) {
	register = new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, .MOVABS, 8, register, Immediate(constant)) or_return
	return
}

@(private)
select_bit_unary :: proc(selector: ^Selector, mnemonic: x86.Mnemonic, value: Vreg, count: i64) -> (register: Vreg, err: Select_Status) {
	register = new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, mnemonic, 8, register, value, Immediate(count)) or_return
	return
}

@(private)
select_bit_binary :: proc(selector: ^Selector, mnemonic: x86.Mnemonic, first, second: Vreg) -> (register: Vreg, err: Select_Status) {
	register = new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, mnemonic, 8, register, first, second) or_return
	return
}
