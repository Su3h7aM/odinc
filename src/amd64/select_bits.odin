package amd64

import "oc:ir"

// The v1 baseline has BSR, BSF and BSWAP; LZCNT and TZCNT need x86-64-v3, so the counts use BSR
// and BSF, and POPCNT needs the feature enabled. Inputs are zero-extended to 64 bits first, which makes
// the 64-bit instructions correct for every width.
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

@(private)
select_population_count :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output, block := selector.input, selector.output, selector.block
	value := select_extended(selector, ir.node_input(input, node, 0), false) or_return
	if .Popcnt in selector.features {
		return emit(output, block, .POPCNT, 8, selector.values[node], value)
	}
	return select_population_count_swar(selector, block, value, selector.values[node])
}

// 64-bit Hacker's Delight population count from v1 instructions. The multiply
// uses the one-operand form, like select_multiply_high; masks come from MOVABS.
@(private)
select_population_count_swar :: proc(selector: ^Selector, block: u32, value, result: Vreg) -> Select_Status {
	output := selector.output
	mask := new_vreg(output, .Int) or_return
	emit(output, block, .MOVABS, 8, mask, Immediate(i64(0x5555555555555555))) or_return
	shifted := new_vreg(output, .Int) or_return
	emit(output, block, .SHR, 8, shifted, value, Immediate(1)) or_return
	pairs := new_vreg(output, .Int) or_return
	emit(output, block, .AND, 8, pairs, shifted, mask) or_return
	twos := new_vreg(output, .Int) or_return
	emit(output, block, .SUB, 8, twos, value, pairs) or_return
	emit(output, block, .MOVABS, 8, mask, Immediate(i64(0x3333333333333333))) or_return
	low := new_vreg(output, .Int) or_return
	emit(output, block, .AND, 8, low, twos, mask) or_return
	emit(output, block, .SHR, 8, shifted, twos, Immediate(2)) or_return
	emit(output, block, .AND, 8, pairs, shifted, mask) or_return
	fours := new_vreg(output, .Int) or_return
	emit(output, block, .ADD, 8, fours, low, pairs) or_return
	emit(output, block, .MOVABS, 8, mask, Immediate(i64(0x0f0f0f0f0f0f0f0f))) or_return
	emit(output, block, .SHR, 8, shifted, fours, Immediate(4)) or_return
	emit(output, block, .ADD, 8, pairs, fours, shifted) or_return
	eights := new_vreg(output, .Int) or_return
	emit(output, block, .AND, 8, eights, pairs, mask) or_return
	emit(output, block, .MOVABS, 8, mask, Immediate(i64(0x0101010101010101))) or_return
	multiplicand := new_vreg(output, .Int) or_return
	product, high := new_vreg(output, .Int) or_return, new_vreg(output, .Int) or_return
	emit_pseudo(output, block, .Copy, multiplicand, eights) or_return
	operands := [?]Machine_Operand{mask, fixed(multiplicand, gpr(.RAX), .Use), fixed(product, gpr(.RAX), .Def), fixed(high, gpr(.RDX), .Def)}
	emit_instruction(output, block, Machine_Instruction{mnemonic = .MUL, width = 8, explicit_count = 1, operands = operands[:]}) or_return
	return emit(output, block, .SHR, 8, result, product, Immediate(56))
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
