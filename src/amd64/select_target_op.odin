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
	fixed_results := make([]Vreg, len(results), selector.allocator) or_return
	for register, index in results {
		fixed_results[index] = new_vreg(output, .Int) or_return
		append(&operands, fixed(fixed_results[index], gpr(register), .Def)) or_return
	}
	emit_instruction(output, selector.block, Machine_Instruction{mnemonic = mnemonic, operands = operands[:]}) or_return
	for fixed_result, index in fixed_results {
		values[index] = new_vreg(output, .Int) or_return
		emit_pseudo(output, selector.block, .Copy, values[index], fixed_result) or_return
	}
	selector.tuples[node] = values
	return nil
}

// RCPSS and RSQRTSS give the hardware's approximation of the single-precision reciprocal and reciprocal square root.
@(private)
select_scalar_float_target_op :: proc(selector: ^Selector, node: ir.Node_Id, mnemonic: x86.Mnemonic) -> Select_Status {
	output := selector.output
	inputs := ir.node_inputs(selector.input, node)
	value := select_value(selector, inputs[2]) or_return
	result := new_vreg(output, .Float) or_return
	emit(output, selector.block, mnemonic, 4, result, value) or_return
	selector.tuples[node] = make([]Vreg, 1, selector.allocator) or_return
	selector.tuples[node][0] = result
	return nil
}

// PREFETCH reads no value and writes no register; the pointer operand is its address.
@(private)
select_prefetch :: proc(selector: ^Selector, node: ir.Node_Id, mnemonic: x86.Mnemonic) -> Select_Status {
	inputs := ir.node_inputs(selector.input, node)
	pointer := select_value(selector, inputs[2]) or_return
	return emit(selector.output, selector.block, mnemonic, 1, Memory_Ref{base = pointer})
}

// The frame base `rbp` is `[rbp + 16]` less 16 (saved `rbp` and return address); `rsp` is the outgoing area's base.
@(private)
select_frame_register :: proc(selector: ^Selector, node: ir.Node_Id, object: Frame_Object, displacement: i32) -> Select_Status {
	result := new_vreg(selector.output, .Int) or_return
	emit(selector.output, selector.block, .LEA, 8, result, Memory_Ref{base = object, displacement = displacement}) or_return
	selector.tuples[node] = make([]Vreg, 1, selector.allocator) or_return
	selector.tuples[node][0] = result
	return nil
}

// Fills the four fields of the `va_list` at the pointer operand for a function whose named parameters are the
// signature's: the registers they took, the first stack word after them, and the register save area of the prologue.
@(private)
select_c_va_start :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	output, block := selector.output, selector.block
	save_slot, has_save_area := output.register_save_slot.?
	if !has_save_area { return select_failure(selector) }
	inputs := ir.node_inputs(selector.input, node)
	list := select_value(selector, inputs[2]) or_return
	named_integers := 0
	for location in selector.assignment.params {
		if location.kind == .Register && location.class == .Int { named_integers += 1 }
	}
	field :: proc(list: Vreg, offset: i32) -> Memory_Ref {
		return Memory_Ref{base = list, displacement = offset}
	}
	emit(output, block, .MOV, 4, field(list, 0), Immediate(8 * named_integers)) or_return
	emit(output, block, .MOV, 4, field(list, 4), Immediate(REGISTER_SAVE_FLOAT_OFFSET + 16 * int(selector.assignment.vector_registers))) or_return
	overflow := new_vreg(output, .Int) or_return
	emit(output, block, .LEA, 8, overflow, Memory_Ref{base = Frame_Object{.Incoming, selector.assignment.stack_bytes}}) or_return
	emit(output, block, .MOV, 8, field(list, 8), overflow) or_return
	area := new_vreg(output, .Int) or_return
	emit(output, block, .LEA, 8, area, Memory_Ref{base = Frame_Object{.Slot, save_slot}}) or_return
	return emit(output, block, .MOV, 8, field(list, 16), area)
}

// The Valgrind client request takes its argument array in RAX and its default in RDX, and leaves the
// result in RDX; the emitter writes the whole special instruction sequence as one unit.
@(private)
select_client_request :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	output := selector.output
	inputs := ir.node_inputs(selector.input, node)
	default_value := select_value(selector, inputs[2]) or_return
	arguments := select_value(selector, inputs[3]) or_return
	default_copy := new_vreg(output, .Int) or_return
	emit_pseudo(output, selector.block, .Copy, default_copy, default_value) or_return
	arguments_copy := new_vreg(output, .Int) or_return
	emit_pseudo(output, selector.block, .Copy, arguments_copy, arguments) or_return
	result := new_vreg(output, .Int) or_return
	operands := make([]Machine_Operand, 3, selector.allocator) or_return
	operands[0] = fixed(default_copy, gpr(.RDX), .Use)
	operands[1] = fixed(arguments_copy, gpr(.RAX), .Use)
	operands[2] = fixed(result, gpr(.RDX), .Def)
	emit_instruction(output, selector.block, Machine_Instruction{mnemonic = .XCHG, pseudo = .Client_Request, operands = operands}) or_return
	selector.tuples[node] = make([]Vreg, 1, selector.allocator) or_return
	selector.tuples[node][0] = result
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
