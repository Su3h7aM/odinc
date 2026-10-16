package amd64

import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "oc:ir"
import "oc:link"
import "oc:regalloc"
import "oc:sched"

@(test)
selected_integer_boundaries :: proc(t: ^testing.T) {
	Case :: struct {
		kind:                ir.Node_Kind,
		type:                ir.Value_Type,
		first, second, want: i64,
	}
	cases := []Case {
		{.Add, .I8, 127, 1, -128},
		{.Sub, .I16, -32768, 1, 32767},
		{.Mul, .I32, 65536, 65536, 0},
		{.And, .I64, 0x1234, 0xff, 0x34},
		{.Or, .I64, 0x1200, 0x34, 0x1234},
		{.Xor, .I64, -1, 0xff, -256},
		{.Shl, .I8, 1, 8, 0},
		{.Shr, .I8, -1, 4, 15},
		{.Shr, .I64, -1, 64, 0},
		{.Shl, .I64, 1, -1, 0},
		{.Sar, .I16, -128, 16, -1},
		{.Sar, .I64, min(i64), -1, -1},
		{.SDiv, .I8, -128, 2, -64},
		{.SRem, .I64, min(i64), -1, 0},
		{.UDiv, .I64, -1, 3, 0x5555555555555555},
		{.URem, .I16, -1, 256, 255},
		{.Zext, .I8, -1, 0, 255},
		{.Sext, .I8, -1, 0, -1},
		{.Sext, .I32, i64(min(i32)), 0, i64(min(i32))},
		{.Trunc, .I64, 0x12345678, 0, 0x78},
	}
	for c in cases {
		function, make_err := ir.function_make(context.allocator, 0, "_start", 0)
		testing.expect_value(t, make_err, nil)
		if make_err != nil { return }
		defer ir.function_destroy(function)
		ir.add_signature(function, ir.Signature{cc = .C})
		entry := ir.start(function)
		first := ir.const_int(function, c.type, c.first)
		second := ir.const_int(function, c.type, c.second)
		value: ir.Node_Id
		result_type := c.type
		#partial switch c.kind {
		case .SDiv, .UDiv, .SRem, .URem:
			value = ir.divide(function, c.kind, entry.control, first, second)
		case .Zext, .Sext:
			result_type = .I64
			value = ir.convert(function, c.kind, first, result_type)
		case .Trunc:
			result_type = .I8
			value = ir.convert(function, c.kind, first, result_type)
		case:
			second = ir.binary(function, .Or, second, ir.const_int(function, c.type, 0))
			value = ir.binary(function, c.kind, first, second)
		}
		correct := ir.compare(function, .Eq, value, ir.const_int(function, result_type, c.want))
		code := ir.select(function, correct, ir.const_int(function, .I64, 55), ir.const_int(function, .I64, 1))
		call := ir.add_node(function, .Syscall, .Tuple, {entry.control, entry.memory, ir.const_int(function, .I64, 231), code})
		memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
		ir.unreachable(function, entry.control, memory)
		testing.expect_value(t, ir.function_finish(function), nil)
		selected_test_run(t, function, 55)
	}
}

@(private)
selected_test_run :: proc(t: ^testing.T, function: ^ir.Function, expected: int, callee: ^ir.Function = nil) {
	schedule, schedule_err := sched.order(function, context.allocator)
	testing.expect_value(t, schedule_err, nil)
	if schedule_err != nil { return }
	defer sched.schedule_destroy(&schedule, context.allocator)
	machine: Machine_Function
	selection_err := select_function(&machine, function, &schedule, {convention = .C})
	testing.expect_value(t, selection_err, Select_Error{})
	if selection_err.kind != .None { return }
	defer machine_function_destroy(&machine)
	testing.expect_value(t, verify_machine(&machine), Verify_Error{})
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	program, program_err := build_program(&machine, virtual.arena_allocator(&arena))
	testing.expect_value(t, program_err, nil)
	if program_err != nil { return }
	result, allocation_err := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result)
	testing.expect_value(t, allocation_err.kind, regalloc.Allocation_Error.None)
	if allocation_err.kind != .None { return }
	symbol_indices: Symbol_Indices
	if callee != nil { symbol_indices[.Function] = []u32{0, 1} }
	atom, emit_err := emit_function(&machine, &result, symbol_indices, context.allocator)
	testing.expect_value(t, emit_err, nil)
	if emit_err != nil { return }
	defer atom_destroy(&atom, context.allocator)
	callee_atom: link.Atom
	defer atom_destroy(&callee_atom, context.allocator)
	atoms := []link.Atom{atom}
	symbols := []link.Symbol{{name = "_start", atom = 0}}
	if callee != nil {
		callee_atom = selected_test_callee(t, callee)
		if len(callee_atom.bytes) == 0 { return }
		atoms = []link.Atom{atom, callee_atom}
		symbols = []link.Symbol{{name = "_start", atom = 0}, {name = callee.name, atom = 1}}
	}
	image, link_err := link.link([]link.Input{{atoms = atoms, symbols = symbols}}, "_start", context.allocator)
	testing.expect_value(t, link_err, nil)
	if link_err != nil { return }
	defer delete(image)
	directory, directory_err := os.make_directory_temp("", "amd64-select-boundary-*", context.temp_allocator)
	testing.expect_value(t, directory_err, nil)
	if directory_err != nil { return }
	path, _ := filepath.join({directory, "boundary"}, context.temp_allocator)
	defer {
		testing.expect(t, os.remove(path) == nil)
		testing.expect(t, os.remove(directory) == nil)
	}
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	testing.expect(t, os.write_entire_file(path, image, permissions) == nil)
	process, process_err := os.process_start(os.Process_Desc{command = []string{path}})
	testing.expect_value(t, process_err, nil)
	if process_err != nil { return }
	state, wait_err := os.process_wait(process)
	testing.expect_value(t, wait_err, nil)
	testing.expect_value(t, state.exit_code, expected)
}

@(private)
selected_test_callee :: proc(t: ^testing.T, function: ^ir.Function) -> link.Atom {
	schedule, schedule_err := sched.order(function, context.allocator)
	testing.expect_value(t, schedule_err, nil)
	if schedule_err != nil { return {} }
	defer sched.schedule_destroy(&schedule, context.allocator)
	machine: Machine_Function
	selection_err := select_function(&machine, function, &schedule, {convention = .C, params = {{type = .I64}}, results = {{type = .I64}}})
	testing.expect_value(t, selection_err, Select_Error{})
	if selection_err.kind != .None { return {} }
	defer machine_function_destroy(&machine)
	testing.expect_value(t, verify_machine(&machine), Verify_Error{})
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	program, program_err := build_program(&machine, virtual.arena_allocator(&arena))
	testing.expect_value(t, program_err, nil)
	if program_err != nil { return {} }
	result, allocation_err := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result)
	testing.expect_value(t, allocation_err.kind, regalloc.Allocation_Error.None)
	if allocation_err.kind != .None { return {} }
	atom, emit_err := emit_function(&machine, &result, {}, context.allocator)
	testing.expect_value(t, emit_err, nil)
	return atom
}

@(test)
selected_call_switch_and_returns :: proc(t: ^testing.T) {
	callee_signature := ir.Signature {
		cc      = .C,
		params  = {{type = .I64}},
		results = {{type = .I64}},
	}
	callee, callee_err := ir.function_make(context.allocator, 1, "choose", 0)
	testing.expect_value(t, callee_err, nil)
	if callee_err != nil { return }
	defer ir.function_destroy(callee)
	ir.add_signature(callee, callee_signature)
	callee_entry := ir.start(callee)
	builder, builder_err := ir.builder_make(context.allocator, callee, callee_entry)
	testing.expect_value(t, builder_err, nil)
	if builder_err != nil { return }
	defer ir.builder_destroy(builder)
	branch := ir.branch_switch(builder, callee_entry.params[0], {1, 7, 10, 100})
	for arm in 0 ..< 5 {
		ir.enter_arm(builder, branch, arm)
		ir.emit_return(builder, ir.const_int(callee, .I64, 55 if arm == 2 else 1))
	}
	testing.expect_value(t, ir.builder_finish(builder), nil)
	caller, caller_err := ir.function_make(context.allocator, 0, "_start", 0)
	testing.expect_value(t, caller_err, nil)
	if caller_err != nil { return }
	defer ir.function_destroy(caller)
	ir.add_signature(caller, ir.Signature{cc = .C})
	callee_index := ir.add_signature(caller, callee_signature)
	entry := ir.start(caller)
	call := ir.call(caller, entry.control, entry.memory, ir.symbol_addr(caller, {.Function, 1}), callee_index, {ir.const_int(caller, .I64, 10)})
	memory := ir.add_node(caller, .Proj, .Memory, {call}, {index = 0})
	value := ir.add_node(caller, .Proj, .I64, {call}, {index = 1})
	exit_call := ir.add_node(caller, .Syscall, .Tuple, {entry.control, memory, ir.const_int(caller, .I64, 231), value})
	memory = ir.add_node(caller, .Proj, .Memory, {exit_call}, {index = 0})
	ir.unreachable(caller, entry.control, memory)
	testing.expect_value(t, ir.function_finish(caller), nil)
	selected_test_run(t, caller, 55, callee)
}

@(test)
selected_memory_and_syscall_arguments :: proc(t: ^testing.T) {
	function, make_err := ir.function_make(context.allocator, 0, "_start", 0)
	testing.expect_value(t, make_err, nil)
	if make_err != nil { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	entry := ir.start(function)
	zero := ir.const_int(function, .I64, 0)
	one := ir.const_int(function, .I64, 1)
	map_call := ir.add_node(
		function,
		.Syscall,
		.Tuple,
		{
			entry.control,
			entry.memory,
			ir.const_int(function, .I64, 9),
			zero,
			ir.const_int(function, .I64, 4096),
			ir.const_int(function, .I64, 3),
			ir.const_int(function, .I64, 0x22),
			ir.const_int(function, .I64, -1),
			zero,
		},
	)
	memory := ir.add_node(function, .Proj, .Memory, {map_call}, {index = 0})
	mapped := ir.add_node(function, .Proj, .I64, {map_call}, {index = 1})
	pointer := ir.convert(function, .Bitcast, mapped, .Ptr)
	allocated := ir.add_node(function, .Stack_Alloc, .Ptr, {entry.control, ir.const_int(function, .I64, 256)}, {index = 16})
	slot := ir.stack_slot(function, entry.control, 16, 16)
	pattern := ir.const_int(function, .I64, 0x0102030405060708)
	memory = ir.store(function, entry.control, memory, pointer, pattern, 0)
	shifted := ir.ptr_offset(function, pointer, 1)
	eight := ir.const_int(function, .I64, 8)
	memory = ir.add_node(function, .Mem_Copy, .Memory, {entry.control, memory, shifted, pointer, eight})
	first := ir.load(function, entry.control, memory, shifted, .I64, 0)
	correct := ir.compare(function, .Eq, first, pattern)
	memory = ir.store(function, entry.control, memory, pointer, pattern, 0)
	variable_size := ir.binary(function, .Add, ir.const_int(function, .I64, 7), one)
	memory = ir.add_node(function, .Mem_Copy, .Memory, {entry.control, memory, shifted, pointer, variable_size})
	second := ir.load(function, entry.control, memory, shifted, .I64, 0)
	correct = ir.binary(function, .And, correct, ir.compare(function, .Eq, second, pattern))
	memory = ir.add_node(function, .Mem_Copy, .Memory, {entry.control, memory, slot, shifted, eight})
	third := ir.load(function, entry.control, memory, slot, .I64, 0)
	correct = ir.binary(function, .And, correct, ir.compare(function, .Eq, third, pattern))
	fill := ir.const_int(function, .I8, 55)
	size := ir.binary(function, .Add, ir.const_int(function, .I64, 129), one)
	memory = ir.add_node(function, .Mem_Set, .Memory, {entry.control, memory, allocated, fill, size})
	last := ir.load(function, entry.control, memory, ir.ptr_offset(function, allocated, 129), .I8, 0)
	correct = ir.binary(function, .And, correct, ir.compare(function, .Eq, last, fill))
	memory = ir.add_node(function, .Mem_Set, .Memory, {entry.control, memory, allocated, fill, ir.const_int(function, .I64, 7)})
	inline_last := ir.load(function, entry.control, memory, ir.ptr_index(function, allocated, ir.const_int(function, .I64, 3), 2), .I8, 0)
	correct = ir.binary(function, .And, correct, ir.compare(function, .Eq, inline_last, fill))
	code := ir.select(function, correct, ir.const_int(function, .I64, 55), one)
	unmap_call := ir.add_node(
		function,
		.Syscall,
		.Tuple,
		{entry.control, memory, ir.const_int(function, .I64, 11), mapped, ir.const_int(function, .I64, 4096)},
	)
	memory = ir.add_node(function, .Proj, .Memory, {unmap_call}, {index = 0})
	exit_call := ir.add_node(function, .Syscall, .Tuple, {entry.control, memory, ir.const_int(function, .I64, 231), code})
	memory = ir.add_node(function, .Proj, .Memory, {exit_call}, {index = 0})
	ir.unreachable(function, entry.control, memory)
	testing.expect_value(t, ir.function_finish(function), nil)
	selected_test_run(t, function, 55)
}

@(test)
selected_loop_exits_with_fifty_five :: proc(t: ^testing.T) {
	function, make_err := ir.function_make(context.allocator, 0, "_start", 0)
	testing.expect_value(t, make_err, nil)
	if make_err != nil { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	entry := ir.start(function)
	builder, builder_err := ir.builder_make(context.allocator, function, entry)
	testing.expect_value(t, builder_err, nil)
	if builder_err != nil { return }
	defer ir.builder_destroy(builder)
	zero := ir.const_int(function, .I64, 0)
	one := ir.const_int(function, .I64, 1)
	ten := ir.const_int(function, .I64, 10)
	index := ir.variable_declare(builder, one)
	sum := ir.variable_declare(builder, zero)
	exit_target := ir.jump_target_make(builder)
	loop := ir.loop_begin(builder, {index, sum})
	branch := ir.branch_if(builder, ir.compare(function, .SLe, ir.variable_get(builder, index), ten))
	ir.enter_arm(builder, branch, 1)
	ir.jump_to(builder, exit_target)
	ir.enter_arm(builder, branch, 0)
	ir.variable_set(builder, sum, ir.binary(function, .Add, ir.variable_get(builder, sum), ir.variable_get(builder, index)))
	ir.variable_set(builder, index, ir.binary(function, .Add, ir.variable_get(builder, index), one))
	ir.loop_end(builder, loop)
	testing.expect(t, ir.seal_target(builder, exit_target))
	exit_number := ir.const_int(function, .I64, 231)
	syscall := ir.add_node(
		function,
		.Syscall,
		.Tuple,
		{builder.control, ir.variable_get(builder, ir.MEMORY_VARIABLE), exit_number, ir.variable_get(builder, sum)},
	)
	memory := ir.add_node(function, .Proj, .Memory, {syscall}, {index = 0})
	ir.unreachable(function, builder.control, memory)
	testing.expect_value(t, ir.builder_finish(builder), nil)

	schedule, schedule_err := sched.order(function, context.allocator)
	testing.expect_value(t, schedule_err, nil)
	if schedule_err != nil { return }
	defer sched.schedule_destroy(&schedule, context.allocator)
	machine: Machine_Function
	selection_err := select_function(&machine, function, &schedule, {convention = .C})
	testing.expect_value(t, selection_err, Select_Error{})
	if selection_err.kind != .None { return }
	defer machine_function_destroy(&machine)
	testing.expect_value(t, verify_machine(&machine), Verify_Error{})
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	program, program_err := build_program(&machine, allocator)
	testing.expect_value(t, program_err, nil)
	if program_err != nil { return }
	move_count := 0
	for block in program.blocks { for moves in block.edge_moves { move_count += len(moves) } }
	testing.expect(t, move_count >= 4, "loop phis must carry entry and backedge parallel copies")

	// Blocked on regalloc E3: resolve_edge_moves is still a no-op.
	if !#config(AMD64_EDGE_MOVES_READY, false) { return }
	result, allocation_err := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result)
	testing.expect_value(t, allocation_err.kind, regalloc.Allocation_Error.None)
	if allocation_err.kind != .None { return }
	testing.expect_value(t, regalloc.resolve_edge_moves(&program, &result).kind, regalloc.Allocation_Error.None)
	atom, emit_err := emit_function(&machine, &result, {}, context.allocator)
	testing.expect_value(t, emit_err, nil)
	if emit_err != nil { return }
	defer atom_destroy(&atom, context.allocator)
	image, link_err := link.link([]link.Input{{atoms = {atom}, symbols = {{name = "_start", atom = 0}}}}, "_start", context.allocator)
	testing.expect_value(t, link_err, nil)
	if link_err != nil { return }
	defer delete(image)
	directory, directory_err := os.make_directory_temp("", "amd64-select-*", context.temp_allocator)
	testing.expect_value(t, directory_err, nil)
	if directory_err != nil { return }
	path, _ := filepath.join({directory, "loop"}, context.temp_allocator)
	defer {
		testing.expect(t, os.remove(path) == nil)
		testing.expect(t, os.remove(directory) == nil)
	}
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	testing.expect(t, os.write_entire_file(path, image, permissions) == nil)
	process, process_err := os.process_start(os.Process_Desc{command = []string{path}})
	testing.expect_value(t, process_err, nil)
	if process_err != nil { return }
	state, wait_err := os.process_wait(process)
	testing.expect_value(t, wait_err, nil)
	testing.expect_value(t, state.exit_code, 55)
}
