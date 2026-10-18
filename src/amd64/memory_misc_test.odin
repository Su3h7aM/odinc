package amd64

import "core:testing"
import "oc:regalloc"

@(test)
memory_misc_instruction_bytes :: proc(t: ^testing.T) {
	function: Machine_Function
	if !testing.expect_value(t, machine_function_init(&function, "memory_misc"), nil) { return }
	defer machine_function_destroy(&function)
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
