package amd64

import x86 "core:rexcode/isa/x86"
import "oc:ir"

@(private)
select_integer :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	kind, type := input.nodes.kind[node], input.nodes.type[node]
	inputs := ir.node_inputs(input, node)
	destination := selector.values[node]
	width := max(4, select_width(type))
	if select_width(type) == 0 { return select_failure(selector) }
	#partial switch kind {
	case .Bitcast:
		value := select_value(selector, inputs[0]) or_return
		if select_width(input.nodes.type[inputs[0]]) != select_width(type) { return select_failure(selector, .Malformed_Input) }
		return emit_pseudo(output, selector.block, .Copy, destination, value)
	case .SDiv, .UDiv, .SRem, .URem:
		return select_division(selector, node)
	case .Mul_Hi_U, .Mul_Hi_S:
		return select_multiply_high(selector, node)
	case .Trunc, .Zext, .Sext:
		value := select_value(selector, inputs[0]) or_return
		from_width := select_width(input.nodes.type[inputs[0]])
		if kind == .Trunc {
			if type == .Bool { return emit(output, selector.block, .AND, 4, destination, value, Immediate(1)) }
			return emit_pseudo(output, selector.block, .Copy, destination, value)
		}
		if from_width < 4 {
			extended := destination
			if kind == .Sext && width == 8 { extended = new_vreg(output, .Int) or_return }
			emit(output, selector.block, .MOVSX if kind == .Sext else .MOVZX, from_width, extended, value) or_return
			if extended != destination { emit(output, selector.block, .MOVSXD, 8, destination, extended) or_return }
			return nil
		}
		return emit(output, selector.block, .MOVSXD if kind == .Sext else .MOV, 8 if kind == .Sext else 4, destination, value)
	case .Select:
		condition := select_value(selector, inputs[0]) or_return
		if_true := select_value(selector, inputs[1]) or_return
		if_false := select_value(selector, inputs[2]) or_return
		emit(output, selector.block, .TEST, 1, condition, condition) or_return
		return emit(output, selector.block, .CMOVNE, width, destination, if_false, if_true)
	case .Eq, .Ne, .SLt, .SLe, .ULt, .ULe:
		byte := new_vreg(output, .Int) or_return
		mnemonics := #partial [ir.Node_Kind]x86.Mnemonic {
			.Eq  = .SETE,
			.Ne  = .SETNE,
			.SLt = .SETL,
			.SLe = .SETLE,
			.ULt = .SETB,
			.ULe = .SETBE,
		}
		select_integer_flags(selector, node) or_return
		emit(output, selector.block, mnemonics[kind], 1, byte) or_return
		return emit(output, selector.block, .MOVZX, 1, destination, byte)
	case .Shl, .Shr, .Sar:
		return select_shift(selector, node)
	}
	left, right := inputs[0], inputs[1]
	is_commutative := kind == .Add || kind == .Mul || kind == .And || kind == .Or || kind == .Xor
	if is_commutative && input.nodes.kind[left] == .Const_Int && input.nodes.kind[right] != .Const_Int {
		left, right = right, left
	}
	first := select_value(selector, left) or_return
	mnemonics := #partial [ir.Node_Kind]x86.Mnemonic {
		.Add = .ADD,
		.Sub = .SUB,
		.Mul = .IMUL,
		.And = .AND,
		.Or  = .OR,
		.Xor = .XOR,
	}
	if immediate, ok := immediate_operand(input, right, width); ok {
		return emit(output, selector.block, mnemonics[kind], width, destination, first, immediate)
	}
	second := select_value(selector, right) or_return
	return emit(output, selector.block, mnemonics[kind], width, destination, first, second)
}

@(private)
select_integer_flags :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	inputs := ir.node_inputs(input, node)
	width := select_width(input.nodes.type[inputs[0]])
	first := select_value(selector, inputs[0]) or_return
	if input.nodes.kind[inputs[1]] == .Const_Int {
		return emit_compare_value(selector, width, first, input.nodes.data[inputs[1]].int_value)
	}
	second := select_value(selector, inputs[1]) or_return
	return emit(selector.output, selector.block, .CMP, width, first, second)
}

// Whether `value` can be the immediate of an instruction whose operands are `width` bytes: the
// encoder keeps the low `width` bytes, and an 8-byte operand sign-extends its imm32.
@(private)
fits_immediate :: proc(value: i64, width: u8) -> bool {
	switch width {
	case 1:
		return -128 <= value && value <= 255
	case 2:
		return -32768 <= value && value <= 65535
	case 4:
		return -2147483648 <= value && value <= 4294967295
	case 8:
		return -2147483648 <= value && value <= 2147483647
	}
	return false
}

@(private)
immediate_operand :: proc(input: ^ir.Function, node: ir.Node_Id, width: u8) -> (immediate: Immediate, ok: bool) {
	if input.nodes.kind[node] != .Const_Int { return }
	value := input.nodes.data[node].int_value
	if !fits_immediate(value, width) { return }
	return Immediate(value), true
}

// Comparing with zero tests the register: TEST sets the same flags as CMP with 0 for every condition code.
@(private)
emit_compare_value :: proc(selector: ^Selector, width: u8, first: Vreg, value: i64) -> Select_Status {
	output, block := selector.output, selector.block
	if value == 0 { return emit(output, block, .TEST, width, first, first) }
	if fits_immediate(value, width) { return emit(output, block, .CMP, width, first, Immediate(value)) }
	constant := new_vreg(output, .Int) or_return
	emit(output, block, .MOVABS if width == 8 else .MOV, max(4, width), constant, Immediate(value)) or_return
	return emit(output, block, .CMP, width, first, constant)
}

@(private)
select_extended :: proc(selector: ^Selector, node: ir.Node_Id, signed: bool) -> (value: Vreg, err: Select_Status) {
	value = select_value(selector, node) or_return
	width := select_width(selector.input.nodes.type[node])
	if width < 4 {
		extended := new_vreg(selector.output, .Int) or_return
		emit(selector.output, selector.block, .MOVSX if signed else .MOVZX, width, extended, value) or_return
		value = extended
	} else if width == 4 && !signed {
		extended := new_vreg(selector.output, .Int) or_return
		emit(selector.output, selector.block, .MOV, 4, extended, value) or_return
		value = extended
	}
	return
}

@(private)
select_shift :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	kind := input.nodes.kind[node]
	inputs := ir.node_inputs(input, node)
	width := select_width(input.nodes.type[node])
	bits := i64(width) * 8
	first := select_extended(selector, inputs[0], kind == .Sar) or_return
	mnemonics := #partial [ir.Node_Kind]x86.Mnemonic {
		.Shl = .SHL,
		.Shr = .SHR,
		.Sar = .SAR,
	}
	mnemonic := mnemonics[kind]
	destination := selector.values[node]
	if input.nodes.kind[inputs[1]] == .Const_Int {
		constant := u64(input.nodes.data[inputs[1]].int_value)
		if constant < u64(bits) { return emit(output, selector.block, mnemonic, max(4, width), destination, first, Immediate(constant)) }
		if kind == .Sar { return emit(output, selector.block, .SAR, max(4, width), destination, first, Immediate(bits - 1)) }
		return emit(output, selector.block, .MOV, 4, destination, Immediate(0))
	}
	count := select_extended(selector, inputs[1], false) or_return
	count_width := max(4, select_width(input.nodes.type[inputs[1]]))
	shift_count := new_vreg(output, .Int) or_return
	if kind == .Sar {
		limit := new_vreg(output, .Int) or_return
		emit(output, selector.block, .MOV, count_width, limit, Immediate(bits - 1)) or_return
		emit(output, selector.block, .CMP, count_width, count, limit) or_return
		emit(output, selector.block, .CMOVA, count_width, shift_count, count, limit) or_return
	} else {
		emit_pseudo(output, selector.block, .Copy, shift_count, count) or_return
	}
	shifted := destination
	if kind != .Sar { shifted = new_vreg(output, .Int) or_return }
	emit(output, selector.block, mnemonic, max(4, width), shifted, first, fixed(shift_count, gpr(.RCX), .Use)) or_return
	if kind != .Sar {
		zero := new_vreg(output, .Int) or_return
		emit(output, selector.block, .MOV, 4, zero, Immediate(0)) or_return
		emit_compare_value(selector, count_width, count, bits) or_return
		emit(output, selector.block, .CMOVAE, max(4, width), destination, shifted, zero) or_return
	}
	return nil
}

@(private)
select_jump :: proc(selector: ^Selector, target: u32) -> Select_Status {
	append(&selector.output.blocks[selector.block].successors, target) or_return
	return emit(selector.output, selector.block, .JMP, 0, Block_Ref(target))
}

@(private)
select_split :: proc(selector: ^Selector, mnemonic: x86.Mnemonic, taken, other: u32) -> Select_Status {
	append(&selector.output.blocks[selector.block].successors, taken, other) or_return
	emit(selector.output, selector.block, mnemonic, 0, Block_Ref(taken)) or_return
	return emit(selector.output, selector.block, .JMP, 0, Block_Ref(other))
}

@(private)
select_division :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	kind := input.nodes.kind[node]
	signed := kind == .SDiv || kind == .SRem
	first := select_extended(selector, ir.node_input(input, node, 1), signed) or_return
	second := select_extended(selector, ir.node_input(input, node, 2), signed) or_return
	width := max(4, select_width(input.nodes.type[node]))
	trap := add_block(output) or_return
	output.blocks[trap].cold = true
	emit(output, trap, .UD2, 0) or_return
	compute := add_block(output) or_return
	emit_compare_value(selector, width, second, 0) or_return
	select_split(selector, .JE, trap, compute) or_return
	selector.block = compute
	if kind == .SDiv {
		minimum_value := i64(-1) << (u32(select_width(input.nodes.type[node])) * 8 - 1)
		is_minimum := new_vreg(output, .Int) or_return
		is_negative_one := new_vreg(output, .Int) or_return
		emit_compare_value(selector, width, first, minimum_value) or_return
		emit(output, selector.block, .SETE, 1, is_minimum) or_return
		emit_compare_value(selector, width, second, -1) or_return
		emit(output, selector.block, .SETE, 1, is_negative_one) or_return
		both := new_vreg(output, .Int) or_return
		emit(output, selector.block, .AND, 1, both, is_minimum, is_negative_one) or_return
		emit(output, selector.block, .TEST, 1, both, both) or_return
		compute = add_block(output) or_return
		select_split(selector, .JNE, trap, compute) or_return
		selector.block = compute
	}
	if kind == .SRem {
		one := new_vreg(output, .Int) or_return
		safe := new_vreg(output, .Int) or_return
		emit(output, selector.block, .MOV, width, one, Immediate(1)) or_return
		emit_compare_value(selector, width, second, -1) or_return
		emit(output, selector.block, .CMOVE, width, safe, second, one) or_return
		second = safe
	}
	dividend := new_vreg(output, .Int) or_return
	high := new_vreg(output, .Int) or_return
	emit_pseudo(output, selector.block, .Copy, dividend, first) or_return
	if signed {
		emit(output, selector.block, .SAR, width, high, first, Immediate(i64(width) * 8 - 1)) or_return
	} else {
		emit(output, selector.block, .MOV, 4, high, Immediate(0)) or_return
	}
	quotient := new_vreg(output, .Int) or_return
	remainder := new_vreg(output, .Int) or_return
	operands := [?]Machine_Operand {
		second,
		fixed(dividend, gpr(.RAX), .Use),
		fixed(high, gpr(.RDX), .Use),
		fixed(quotient, gpr(.RAX), .Def),
		fixed(remainder, gpr(.RDX), .Def),
	}
	emit_instruction(
		output,
		selector.block,
		Machine_Instruction{mnemonic = .IDIV if signed else .DIV, width = width, explicit_count = 1, operands = operands[:]},
	) or_return
	return emit_pseudo(output, selector.block, .Copy, selector.values[node], remainder if kind == .SRem || kind == .URem else quotient)
}

@(private)
select_multiply_high :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	signed := input.nodes.kind[node] == .Mul_Hi_S
	first := select_value(selector, ir.node_input(input, node, 0)) or_return
	second := select_value(selector, ir.node_input(input, node, 1)) or_return
	multiplicand := new_vreg(output, .Int) or_return
	low := new_vreg(output, .Int) or_return
	high := new_vreg(output, .Int) or_return
	emit_pseudo(output, selector.block, .Copy, multiplicand, first) or_return
	operands := [?]Machine_Operand{second, fixed(multiplicand, gpr(.RAX), .Use), fixed(low, gpr(.RAX), .Def), fixed(high, gpr(.RDX), .Def)}
	emit_instruction(
		output,
		selector.block,
		Machine_Instruction{mnemonic = .IMUL if signed else .MUL, width = 8, explicit_count = 1, operands = operands[:]},
	) or_return
	return emit_pseudo(output, selector.block, .Copy, selector.values[node], high)
}
