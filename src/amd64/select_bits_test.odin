package amd64

import "core:testing"
import "oc:ir"
import "oc:sched"

@(test)
selected_population_count_is_one_popcnt :: proc(t: ^testing.T) {
	function, make_err := ir.function_make(context.allocator, 0, "_start", 0)
	testing.expect_value(t, make_err, nil)
	if make_err != nil { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	entry := ir.start(function)
	count := ir.unary(function, .Popcnt, ir.const_int(function, .I64, 0x5555555555555555))
	call := ir.add_node(function, .Syscall, .Tuple, {entry.control, entry.memory, ir.const_int(function, .I64, 231), count})
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.unreachable(function, entry.control, memory)
	testing.expect_value(t, ir.function_finish(function), nil)

	schedule, schedule_err := sched.order(function, context.allocator)
	testing.expect_value(t, schedule_err, nil)
	if schedule_err != nil { return }
	defer sched.schedule_destroy(&schedule, context.allocator)
	machine: Machine_Function
	selection_err := select_function(&machine, function, &schedule, {convention = .C}, .V2)
	testing.expect_value(t, selection_err, Select_Error{})
	if selection_err.kind != .None { return }
	defer machine_function_destroy(&machine)
	popcnt_count := 0
	for block in machine.blocks {
		for instruction in block.instructions {
			if instruction.mnemonic == .POPCNT { popcnt_count += 1 }
		}
	}
	testing.expect_value(t, popcnt_count, 1)
}

@(test)
selected_population_count_falls_back_without_popcnt :: proc(t: ^testing.T) {
	function, make_err := ir.function_make(context.allocator, 0, "_start", 0)
	testing.expect_value(t, make_err, nil)
	if make_err != nil { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	entry := ir.start(function)
	count := ir.unary(function, .Popcnt, ir.const_int(function, .I64, 0x5555555555555555))
	call := ir.add_node(function, .Syscall, .Tuple, {entry.control, entry.memory, ir.const_int(function, .I64, 231), count})
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.unreachable(function, entry.control, memory)
	testing.expect_value(t, ir.function_finish(function), nil)

	schedule, schedule_err := sched.order(function, context.allocator)
	testing.expect_value(t, schedule_err, nil)
	if schedule_err != nil { return }
	defer sched.schedule_destroy(&schedule, context.allocator)
	machine: Machine_Function
	selection_err := select_function(&machine, function, &schedule, {convention = .C}, .V1)
	testing.expect_value(t, selection_err, Select_Error{})
	if selection_err.kind != .None { return }
	defer machine_function_destroy(&machine)
	popcnt_count, multiply_count := 0, 0
	for block in machine.blocks {
		for instruction in block.instructions {
			if instruction.mnemonic == .POPCNT { popcnt_count += 1 }
			if instruction.mnemonic == .MUL { multiply_count += 1 }
		}
	}
	testing.expect_value(t, popcnt_count, 0)
	testing.expect_value(t, multiply_count, 1)
}
