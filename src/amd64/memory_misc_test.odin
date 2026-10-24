package amd64

import "core:mem/virtual"
import "core:slice"
import "core:testing"
import "oc:ir"
import "oc:regalloc"

@(test)
memory_misc_instruction_bytes :: proc(t: ^testing.T) {
	function: Machine_Function
	if !testing.expect_value(t, machine_function_init(&function, "memory_misc"), nil) { return }
	block, block_error := add_block(&function)
	if !testing.expect_value(t, block_error, nil) { return }
	testing.expect_value(t, emit(&function, block, .PAUSE, 0), nil)
	testing.expect_value(t, emit(&function, block, .INT3, 0), nil)
	testing.expect_value(t, emit(&function, block, .UD2, 0), nil)
	program, program_error := build_program(&function, context.temp_allocator)
	if !testing.expect_value(t, program_error, nil) { return }
	result, allocation_error := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result)
	if !testing.expect_value(t, allocation_error.kind, regalloc.Allocation_Error.None) { return }
	atom, emit_error := emit_function(&function, &result, {}, context.allocator)
	if !testing.expect_value(t, emit_error, nil) { return }
	defer atom_destroy(&atom, context.allocator)
	found := false
	for index in 0 ..< max(0, len(atom.bytes) - 4) {
		if atom.bytes[index] == 0xf3 &&
		   atom.bytes[index + 1] == 0x90 &&
		   atom.bytes[index + 2] == 0xcc &&
		   atom.bytes[index + 3] == 0x0f &&
		   atom.bytes[index + 4] == 0x0b { found = true }
	}
	testing.expect(t, found)
}

@(test)
client_request_emits_valgrind_special_sequence :: proc(t: ^testing.T) {
	function: Machine_Function
	if !testing.expect_value(t, machine_function_init(&function, "client_request"), nil) { return }
	block, block_error := add_block(&function)
	if !testing.expect_value(t, block_error, nil) { return }
	default_value, array, result: Vreg
	default_value, _ = new_vreg(&function, .Int)
	array, _ = new_vreg(&function, .Int)
	result, _ = new_vreg(&function, .Int)
	testing.expect_value(t, emit(&function, block, .MOV, 8, default_value, Immediate(0)), nil)
	testing.expect_value(t, emit(&function, block, .MOV, 8, array, Immediate(0)), nil)
	operands := []Machine_Operand{fixed(default_value, gpr(.RDX), .Use), fixed(array, gpr(.RAX), .Use), fixed(result, gpr(.RDX), .Def)}
	testing.expect_value(t, emit_instruction(&function, block, Machine_Instruction{mnemonic = .XCHG, pseudo = .Client_Request, operands = operands}), nil)
	testing.expect_value(t, emit(&function, block, .UD2, 0), nil)
	program, program_error := build_program(&function, context.temp_allocator)
	if !testing.expect_value(t, program_error, nil) { return }
	result_allocation, allocation_error := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result_allocation)
	if !testing.expect_value(t, allocation_error.kind, regalloc.Allocation_Error.None) { return }
	atom, emit_error := emit_function(&function, &result_allocation, {}, context.allocator)
	if !testing.expect_value(t, emit_error, nil) { return }
	defer atom_destroy(&atom, context.allocator)
	sequence := [?]u8{0x48, 0xc1, 0xc7, 0x03, 0x48, 0xc1, 0xc7, 0x0d, 0x48, 0xc1, 0xc7, 0x3d, 0x48, 0xc1, 0xc7, 0x33, 0x48, 0x87, 0xdb}
	found := false
	for index in 0 ..= max(0, len(atom.bytes) - len(sequence)) {
		if index + len(sequence) <= len(atom.bytes) && slice.equal(atom.bytes[index:index + len(sequence)], sequence[:]) { found = true }
	}
	testing.expect(t, found)
}

@(test)
variadic_prologue_saves_the_unnamed_argument_registers :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	signature := ir.Signature {
		cc       = .C,
		variadic = true,
		params   = []ir.Param{{type = .I32}},
	}
	assignment, abi_error := assign_signature(signature, allocator)
	testing.expect_value(t, abi_error, nil)
	function: Machine_Function
	if !testing.expect_value(t, machine_function_init(&function, "variadic"), nil) { return }
	block, _ := add_block(&function)
	params, start_error := lower_start(&function, block, signature, assignment, allocator)
	testing.expect_value(t, start_error, nil)
	testing.expect_value(t, lower_return(&function, block, signature, assignment, params, nil, allocator), nil)
	slot, has_slot := function.register_save_slot.?
	testing.expect(t, has_slot)
	testing.expect_value(t, function.frame_slots[slot], Frame_Slot{REGISTER_SAVE_AREA_BYTES, 16})
	program, program_error := build_program(&function, allocator)
	testing.expect_value(t, program_error, nil)
	result, allocation_error := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result)
	testing.expect_value(t, allocation_error.kind, regalloc.Allocation_Error.None)
	atom, emit_error := emit_function(&function, &result, {}, context.allocator)
	if !testing.expect_value(t, emit_error, nil) { return }
	defer atom_destroy(&atom, context.allocator)
	vector_stores, integer_stores := 0, 0
	for index in 0 ..< len(atom.bytes) - 2 {
		if atom.bytes[index] == 0x0f && atom.bytes[index + 1] == 0x11 { vector_stores += 1 }
		if (atom.bytes[index] == 0x48 || atom.bytes[index] == 0x4c) &&
		   atom.bytes[index + 1] == 0x89 &&
		   atom.bytes[index + 2] & 0xc7 == 0x85 { integer_stores += 1 }
	}
	testing.expect_value(t, vector_stores, 8)
	testing.expect_value(t, integer_stores, 5)
}
