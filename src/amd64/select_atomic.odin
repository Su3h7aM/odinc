package amd64

import x86 "core:rexcode/isa/x86"
import "oc:ir"

@(private)
select_atomic :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	kind := input.nodes.kind[node]
	access := input.nodes.data[node].access
	if kind == .Fence {
		if access.order == .Seq_Cst && !access.signal { return emit(output, selector.block, .MFENCE, 0) }
		return nil
	}
	inputs := ir.node_inputs(input, node)
	address := select_address(selector, inputs[2]) or_return
	old := new_vreg(output, .Int) or_return
	selector.tuples[node] = make([]Vreg, 2 if kind == .Atomic_Cas else 1, selector.allocator) or_return
	selector.tuples[node][0] = old
	if kind == .Load_Ordered {
		if mnemonic, width, is_float := float_move(access.value_type); is_float {
			old = new_vreg(output, .Float) or_return
			selector.tuples[node][0] = old
			return emit(output, selector.block, mnemonic, width, old, address)
		}
		width := select_width(access.value_type)
		if width == 0 { return select_failure(selector) }
		return emit(output, selector.block, .MOVZX if width < 4 else .MOV, width, old, address)
	}
	width := select_width(input.nodes.type[inputs[3]])
	if width == 0 { return select_failure(selector) }
	value := select_value(selector, inputs[3]) or_return
	accumulator := new_vreg(output, .Int) or_return
	mnemonic := x86.Mnemonic.CMPXCHG
	if kind == .Atomic_Rmw {
		switch access.rmw {
		case .Add:
			mnemonic = .XADD
		case .Sub:
			mnemonic = .XADD
		case .Xchg:
			mnemonic = .XCHG
		case .And:
			mnemonic = .AND
		case .Nand:
			mnemonic = .NOT
		case .Or:
			mnemonic = .OR
		case .Xor:
			mnemonic = .XOR
		}
	}
	bitwise := kind == .Atomic_Rmw && mnemonic != .XADD && mnemonic != .XCHG
	if bitwise {
		preserved := new_vreg(output, .Int) or_return
		emit_pseudo(output, selector.block, .Copy, preserved, value) or_return
		value = preserved
	}
	emit_pseudo(output, selector.block, .Copy, accumulator, value) or_return
	if kind == .Atomic_Rmw && access.rmw == .Sub {
		negated := new_vreg(output, .Int) or_return
		emit(output, selector.block, .NEG, width, negated, accumulator) or_return
		accumulator = negated
	}
	operands := make([dynamic]Machine_Operand, selector.allocator) or_return
	append(&operands, address, fixed(accumulator, gpr(.RAX), .Use_Def)) or_return
	if kind == .Atomic_Cas {
		replacement := select_value(selector, inputs[4]) or_return
		append(&operands, replacement) or_return
	} else if mnemonic != .XADD && mnemonic != .XCHG {
		temporary := new_vreg(output, .Int) or_return
		emit(output, selector.block, .MOV, 4, temporary, Immediate(0)) or_return
		append(&operands, fixed(value, gpr(.RCX), .Use), fixed(temporary, gpr(.RDX), .Use_Def)) or_return
	}
	emit_instruction(output, selector.block, Machine_Instruction{pseudo = .Atomic, mnemonic = mnemonic, width = width, operands = operands[:]}) or_return
	if kind == .Atomic_Cas {
		success := new_vreg(output, .Int) or_return
		selector.tuples[node][1] = success
		emit(output, selector.block, .SETE, 1, success) or_return
	}
	return emit(output, selector.block, .MOVZX if width < 4 else .MOV, width, old, accumulator)
}
