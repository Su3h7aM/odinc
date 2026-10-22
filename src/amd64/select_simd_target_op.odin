package amd64

import x86 "core:rexcode/isa/x86"
import "oc:ir"
import "oc:regalloc"

// Selects an XMM operation on 128-bit values. The result is a new XMM register; for the two-operand forms the
// allocator binds it to the first operand (see `op_info`). AESKEYGENASSIST takes its immediate from a constant node.
@(private)
select_simd_target_op :: proc(selector: ^Selector, node: ir.Node_Id, mnemonic: x86.Mnemonic) -> Select_Status {
	output, block := selector.output, selector.block
	inputs := ir.node_inputs(selector.input, node)
	first := select_value(selector, inputs[2]) or_return
	destination := new_vreg(output, .Float) or_return
	#partial switch mnemonic {
	case .AESIMC:
		emit(output, block, mnemonic, 16, destination, first) or_return
	case .AESKEYGENASSIST:
		immediate := selector.input.nodes.data[inputs[3]].int_value
		emit(output, block, mnemonic, 16, destination, first, Immediate(immediate)) or_return
	case .PCLMULQDQ:
		second := select_value(selector, inputs[3]) or_return
		immediate := selector.input.nodes.data[inputs[4]].int_value
		emit(output, block, mnemonic, 16, destination, first, second, Immediate(immediate)) or_return
	case .SHA256RNDS2:
		second := select_value(selector, inputs[3]) or_return
		constant := select_value(selector, inputs[4]) or_return
		operands := [4]Machine_Operand{destination, first, second, fixed(constant, regalloc.Register(0), .Use)}
		emit_instruction(output, block, Machine_Instruction{mnemonic = mnemonic, width = 16, explicit_count = 3, operands = operands[:]}) or_return
	case:
		second := select_value(selector, inputs[3]) or_return
		emit(output, block, mnemonic, 16, destination, first, second) or_return
	}
	tuple := make([]Vreg, 1, selector.allocator) or_return
	tuple[0] = destination
	selector.tuples[node] = tuple
	return nil
}
