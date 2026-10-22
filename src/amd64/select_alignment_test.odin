package amd64

import "core:testing"
import "oc:ir"

@(test)
selected_over_aligned_slots_preserve_escaped_and_folded_addresses :: proc(t: ^testing.T) {
	function, make_error := ir.function_make(context.allocator, 0, "_start", 0)
	if !testing.expect_value(t, make_error, nil) { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	entry := ir.start(function)
	memory := entry.memory
	correct := ir.const_int(function, .Bool, 1)
	alignments := [?]u32{32, 64}
	for alignment in alignments {
		slot := ir.stack_slot(function, entry.control, 17, alignment)
		integer := ir.convert(function, .Bitcast, slot, .I64)
		escaped := ir.convert(function, .Bitcast, integer, .Ptr)
		misalignment := ir.binary(function, .And, integer, ir.const_int(function, .I64, i64(alignment - 1)))
		correct = ir.binary(function, .And, correct, ir.compare(function, .Eq, misalignment, ir.const_int(function, .I64, 0)))
		memory = ir.store(function, entry.control, memory, ir.ptr_offset(function, escaped, 5), ir.const_int(function, .I8, 0), 0)
		indexed := ir.ptr_index(function, ir.ptr_offset(function, slot, 1), ir.const_int(function, .I64, 2), 2)
		memory = ir.store(function, entry.control, memory, indexed, ir.const_int(function, .I8, 77), 0)
		loaded := ir.load(function, entry.control, memory, ir.ptr_offset(function, escaped, 5), .I8, 0)
		correct = ir.binary(function, .And, correct, ir.compare(function, .Eq, loaded, ir.const_int(function, .I8, 77)))
		memory = ir.store(function, entry.control, memory, ir.ptr_offset(function, escaped, 16), ir.const_int(function, .I8, 99), 0)
		loaded = ir.load(function, entry.control, memory, ir.ptr_offset(function, slot, 16), .I8, 0)
		correct = ir.binary(function, .And, correct, ir.compare(function, .Eq, loaded, ir.const_int(function, .I8, 99)))
	}
	exit_code := ir.convert(function, .Zext, ir.binary(function, .Xor, correct, ir.const_int(function, .Bool, 1)), .I64)
	exit_call := ir.add_node(function, .Syscall, .Tuple, {entry.control, memory, ir.const_int(function, .I64, 231), exit_code})
	memory = ir.add_node(function, .Proj, .Memory, {exit_call}, {index = 0})
	ir.unreachable(function, entry.control, memory)
	if !testing.expect_value(t, ir.function_finish(function), nil) { return }
	selected_test_run(t, function, 0)
}
