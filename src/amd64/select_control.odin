package amd64

import "oc:ir"
import "oc:regalloc"

@(private)
select_exit :: proc(selector: ^Selector, block: ir.Block_Id) -> Select_Status {
	input, output := selector.input, selector.output
	exit := selector.schedule.cfg.exits[block]
	edges := selector.edges[block]
	if exit == ir.NODE_NONE {
		if len(edges) != 1 { return select_failure(selector, .Malformed_Input) }
		return select_jump(selector, edges[0])
	}
	inputs := ir.node_inputs(input, exit)
	#partial switch input.nodes.kind[exit] {
	case .If:
		if len(edges) != 2 { return select_failure(selector, .Malformed_Input) }
		condition := select_value(selector, inputs[1]) or_return
		emit(output, selector.block, .TEST, 1, condition, condition) or_return
		return select_split(selector, .JNE, edges[0], edges[1])
	case .Switch:
		index := input.nodes.data[exit].index
		if int(index) >= len(input.tables) { return select_failure(selector, .Malformed_Input) }
		cases := input.tables[index]
		if len(edges) != len(cases) + 1 { return select_failure(selector, .Malformed_Input) }
		value := select_value(selector, inputs[1]) or_return
		width := select_width(input.nodes.type[inputs[1]])
		for case_value, case_index in cases {
			constant := new_vreg(output, .Int) or_return
			emit(output, selector.block, .MOVABS if width == 8 else .MOV, max(4, width), constant, Immediate(case_value)) or_return
			emit(output, selector.block, .CMP, width, value, constant) or_return
			next := add_block(output) or_return
			select_split(selector, .JE, edges[case_index], next) or_return
			selector.block = next
		}
		return select_jump(selector, edges[len(cases)])
	case .Return:
		values := make([]Vreg, len(inputs) - 2, selector.allocator) or_return
		for node, index in inputs[2:] { values[index] = select_value(selector, node) or_return }
		lower_return(output, selector.block, selector.signature, selector.assignment, selector.params, values, selector.allocator) or_return
		return nil
	case .Trap, .Unreachable:
		return emit(output, selector.block, .UD2, 0)
	}
	return select_failure(selector)
}

@(private)
select_call :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	inputs := ir.node_inputs(input, node)
	if input.nodes.kind[node] == .Call {
		index := input.nodes.data[node].index
		if int(index) >= len(input.signatures) { return select_failure(selector, .Malformed_Input) }
		signature := input.signatures[index]
		assignment := assign_signature(signature, selector.allocator) or_return
		args := make([]Vreg, len(inputs) - 3, selector.allocator) or_return
		for argument, argument_index in inputs[3:] { args[argument_index] = select_value(selector, argument) or_return }
		callee: Callee
		if input.nodes.kind[inputs[2]] == .Symbol_Addr {
			callee = Symbol_Target {
				symbol = input.nodes.data[inputs[2]].symbol,
			}
		} else {
			callee = select_value(selector, inputs[2]) or_return
		}
		selector.tuples[node] = lower_call(output, selector.block, signature, assignment, callee, args, selector.allocator) or_return
		return nil
	}
	registers := [?]Gpr{.RAX, .RDI, .RSI, .RDX, .R10, .R8, .R9}
	operands := make([dynamic]Machine_Operand, 0, 8, selector.allocator) or_return
	if len(inputs) > 9 { return select_failure(selector, .Malformed_Input) }
	for argument, index in inputs[2:] {
		value := select_value(selector, argument) or_return
		copy := new_vreg(output, .Int) or_return
		emit_pseudo(output, selector.block, .Copy, copy, value) or_return
		if registers[index] == .R10 {
			append(&operands, copy) or_return
		} else {
			append(&operands, fixed(copy, gpr(registers[index]), .Use)) or_return
		}
	}
	result := new_vreg(output, .Int) or_return
	append(&operands, fixed(result, gpr(.RAX), .Def)) or_return
	clobbers: [Register_Class]regalloc.Register_Set
	clobbers[.Int] = {int(Gpr.RCX), int(Gpr.R11)}
	emit_instruction(
		output,
		selector.block,
		Machine_Instruction{mnemonic = .SYSCALL, pseudo = .Syscall, operands = operands[:], clobbers = clobbers},
	) or_return
	selector.tuples[node] = make([]Vreg, 1, selector.allocator) or_return
	selector.tuples[node][0] = result
	return nil
}
