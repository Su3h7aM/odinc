package amd64

import x86 "core:rexcode/isa/x86"
import "oc:ir"

// Passes the arguments in `arguments` registers and returns the values of `results` registers, as one instruction
// whose operands are all fixed registers.
@(private)
select_fixed_target_op :: proc(selector: ^Selector, node: ir.Node_Id, mnemonic: x86.Mnemonic, arguments, results: []Gpr) -> Select_Status {
	input, output := selector.input, selector.output
	inputs := ir.node_inputs(input, node)
	operands := make([dynamic]Machine_Operand, 0, len(arguments) + len(results), selector.allocator) or_return
	for register, index in arguments {
		value := select_value(selector, inputs[2 + index]) or_return
		argument := new_vreg(output, .Int) or_return
		emit_pseudo(output, selector.block, .Copy, argument, value) or_return
		append(&operands, fixed(argument, gpr(register), .Use)) or_return
	}
	values := make([]Vreg, len(results), selector.allocator) or_return
	for register, index in results {
		values[index] = new_vreg(output, .Int) or_return
		append(&operands, fixed(values[index], gpr(register), .Def)) or_return
	}
	emit_instruction(output, selector.block, Machine_Instruction{mnemonic = mnemonic, operands = operands[:]}) or_return
	selector.tuples[node] = values
	return nil
}

// RDTSC returns the counter in EDX:EAX; the result is EDX shifted up 32 bits, or'ed with EAX.
@(private)
select_read_cycle_counter :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	output := selector.output
	select_fixed_target_op(selector, node, .RDTSC, nil, []Gpr{.RAX, .RDX}) or_return
	halves := selector.tuples[node]
	low, high := halves[0], halves[1]
	shifted := new_vreg(output, .Int) or_return
	emit(output, selector.block, .SHL, 8, shifted, high, Immediate(32)) or_return
	counter := new_vreg(output, .Int) or_return
	emit(output, selector.block, .OR, 8, counter, shifted, low) or_return
	tuple := make([]Vreg, 1, selector.allocator) or_return
	tuple[0] = counter
	selector.tuples[node] = tuple
	return nil
}
