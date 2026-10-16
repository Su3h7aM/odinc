package ir

import "base:runtime"
import "core:testing"

@(test)
interp_sums_to_n :: proc(t: ^testing.T) {
	module: Module
	testing.expect_value(t, module_init(&module), nil)
	defer module_destroy(&module)

	fn, make_err := function_make(context.allocator, 0, "main.sum", 0)
	testing.expect_value(t, make_err, nil)
	_, append_err := append(&module.functions, fn)
	testing.expect_value(t, append_err, nil)

	add_signature(fn, Signature{cc = .C, params = {{type = .I64}}, results = {{type = .I64}}})
	entry := start(fn)
	n := entry.params[0]
	b, builder_err := builder_make(context.allocator, fn, entry)
	testing.expect_value(t, builder_err, nil)
	defer builder_destroy(b)

	zero, one := const_int(fn, .I64, 0), const_int(fn, .I64, 1)
	i := variable_declare(b, one)
	sum := variable_declare(b, zero)

	exit_target := jump_target_make(b)
	loop := loop_begin(b, {i, sum})
	continue_target := jump_target_make(b)
	exit := branch_if(b, compare(fn, .SLe, variable_get(b, i), n))
	enter_arm(b, exit, 1)
	jump_to(b, exit_target)
	enter_arm(b, exit, 0)

	variable_set(b, sum, binary(fn, .Add, variable_get(b, sum), variable_get(b, i)))
	jump_to(b, continue_target)
	testing.expect(t, seal_target(b, continue_target))
	variable_set(b, i, binary(fn, .Add, variable_get(b, i), one))
	loop_end(b, loop)
	testing.expect(t, seal_target(b, exit_target))

	emit_return(b, variable_get(b, sum))
	testing.expect_value(t, builder_finish(b), nil)

	cases := [?]struct {
		n, sum: u64,
	}{{0, 0}, {1, 1}, {10, 55}, {100, 5050}}
	for c in cases {
		result, err := interp_run(&module, fn, []u64{c.n}, 10_000, context.allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, result.outcome, Interp_Outcome.Value)
		testing.expect_value(t, result.value, c.sum)
	}
}

Edge_Case :: struct {
	kind:          Node_Kind,
	type:          Value_Type,
	count_type:    Value_Type,
	a, b:          u64,
	guard_divisor: bool,
	outcome:       Interp_Outcome,
	value:         u64,
}

@(private = "file")
edge_constant :: proc(fn: ^Function, type: Value_Type, bits_value: u64) -> Node_Id {
	if interp_is_float(type) {
		return const_float(fn, type, bits_value)
	}
	return const_int(fn, type, i64(bits_value))
}

@(private = "file")
edge_node :: proc(fn: ^Function, control: Node_Id, c: Edge_Case) -> Node_Id {
	a := edge_constant(fn, c.type, c.a)
	count_type := c.count_type if c.count_type != .None else c.type
	b := edge_constant(fn, count_type, c.b)
	#partial switch c.kind {
	case .SDiv, .UDiv, .SRem, .URem:
		divisor := b
		if c.guard_divisor {
			minus_one := const_int(fn, c.type, -1)
			divisor = select(fn, compare(fn, .Eq, b, minus_one), const_int(fn, c.type, 1), b)
		}
		return divide(fn, c.kind, control, a, divisor)
	case .Eq, .Ne, .SLt, .SLe, .ULt, .ULe, .FEq, .FLt, .FLe, .FNe:
		return compare(fn, c.kind, a, b)
	case .Clz, .Ctz, .Popcnt, .Bswap, .FNeg, .FSqrt:
		return unary(fn, c.kind, a)
	}
	return binary(fn, c.kind, a, b)
}

@(private = "file")
edge_result :: proc(t: ^testing.T, module: ^Module, c: Edge_Case) -> Interp_Result {
	fn, make_err := function_make(context.allocator, 0, "main.edge", 0)
	testing.expect_value(t, make_err, nil)
	_, append_err := append(&module.functions, fn)
	testing.expect_value(t, append_err, nil)

	result_type := c.type
	#partial switch c.kind {
	case .Eq, .Ne, .SLt, .SLe, .ULt, .ULe, .FEq, .FLt, .FLe, .FNe:
		result_type = .Bool
	}
	add_signature(fn, Signature{cc = .C, results = {{type = result_type}}})
	entry := start(fn)
	b, builder_err := builder_make(context.allocator, fn, entry)
	testing.expect_value(t, builder_err, nil)
	defer builder_destroy(b)

	result := edge_node(fn, entry.control, c)
	emit_return(b, result)
	testing.expect_value(t, builder_finish(b), nil)

	outcome, err := interp_run(module, fn, nil, 100, context.allocator)
	testing.expect_value(t, err, nil)
	return outcome
}

@(test)
interp_arithmetic_edges :: proc(t: ^testing.T) {
	module: Module
	testing.expect_value(t, module_init(&module), nil)
	defer module_destroy(&module)

	cases := [?]Edge_Case {
		// Shifts: counts at or above the width, count read unsigned in its own width, arithmetic sign fill.
		{kind = .Shl, type = .I8, count_type = .I64, a = 0x81, b = 8, outcome = .Value, value = 0},
		{kind = .Shr, type = .I8, count_type = .I8, a = 0x80, b = 0xFF, outcome = .Value, value = 0},
		{kind = .Sar, type = .I8, count_type = .I64, a = 0x80, b = 8, outcome = .Value, value = 0xFF},
		{kind = .Sar, type = .I8, count_type = .I8, a = 0x80, b = 3, outcome = .Value, value = 0xF0},
		// Division: truncation toward zero, MIN / -1 and MIN % -1 trap at the hardware level, guard gives 0.
		{kind = .SDiv, type = .I8, a = 0xF9, b = 2, outcome = .Value, value = 0xFD},
		{kind = .SRem, type = .I8, a = 0xF9, b = 2, outcome = .Value, value = 0xFF},
		{kind = .UDiv, type = .I8, a = 0xFF, b = 2, outcome = .Value, value = 0x7F},
		{kind = .SDiv, type = .I8, a = 0x80, b = 0xFF, outcome = .Arith_Trap},
		{kind = .SRem, type = .I8, a = 0x80, b = 0xFF, outcome = .Arith_Trap},
		{kind = .SRem, type = .I8, a = 0x80, b = 0xFF, guard_divisor = true, outcome = .Value, value = 0},
		{kind = .SDiv, type = .I32, a = 7, b = 0, outcome = .Arith_Trap},
		// Integer wrap and signed versus unsigned compare.
		{kind = .Add, type = .I8, a = 0x7F, b = 1, outcome = .Value, value = 0x80},
		{kind = .SLt, type = .I8, a = 0xFF, b = 1, outcome = .Value, value = 1},
		{kind = .ULt, type = .I8, a = 0xFF, b = 1, outcome = .Value, value = 0},
		// Clz and Ctz of zero give the width.
		{kind = .Clz, type = .I32, a = 0, outcome = .Value, value = 32},
		{kind = .Ctz, type = .I8, a = 0, outcome = .Value, value = 8},
		// F32 addition rounds to 32 bits: 2^24 + 1 is 2^24.
		{kind = .FAdd, type = .F32, a = 0x4B800000, b = 0x3F800000, outcome = .Value, value = 0x4B800000},
	}
	for c in cases {
		result := edge_result(t, &module, c)
		testing.expectf(
			t,
			result.outcome == c.outcome && result.value == c.value,
			"%v %v: got %v %x, want %v %x",
			c.kind,
			c.type,
			result.outcome,
			result.value,
			c.outcome,
			c.value,
		)
	}
}

@(private = "file")
memory_function :: proc(t: ^testing.T, result: Value_Type) -> (fn: ^Function, entry: Start_Nodes) {
	err: runtime.Allocator_Error
	fn, err = function_make(context.allocator, 0, "main.memory", 0)
	testing.expect_value(t, err, nil)
	add_signature(fn, Signature{cc = .C, results = {{type = result}}})
	entry = start(fn)
	return
}

@(private = "file")
memory_finish :: proc(t: ^testing.T, module: ^Module, fn: ^Function, control, memory, value: Node_Id) -> Interp_Result {
	ret(fn, control, memory, value)
	testing.expect_value(t, function_finish(fn), nil)
	_, append_err := append(&module.functions, fn)
	testing.expect_value(t, append_err, nil)
	result, err := interp_run(module, fn, nil, 1000, context.allocator)
	testing.expect_value(t, err, nil)
	return result
}

@(test)
interp_memory_model :: proc(t: ^testing.T) {
	module: Module
	testing.expect_value(t, module_init(&module), nil)
	defer module_destroy(&module)

	globals := [?]Global {
		{name = "table", size = 16, align = 8, mutable = true, relocs = []Data_Reloc{{offset = 8, target = {space = .Global, index = 1}, addend = 4}}},
		{name = "target", size = 16, align = 8, bytes = []byte{0, 0, 0, 0, 0x2A}},
		{name = "local", size = 8, align = 8, tls = true, bytes = []byte{0x00, 0x01}},
	}
	for global in globals {
		_, append_err := append(&module.globals, global)
		testing.expect_value(t, append_err, nil)
	}

	scalars := [?]struct {
		type: Value_Type,
		bits: u64,
	}{{.I8, 0xA5}, {.I16, 0xBEEF}, {.I32, 0xDEADBEEF}, {.I64, 0x0123456789ABCDEF}, {.F32, 0x3FC00000}, {.F64, 0x3FF8000000000000}, {.Ptr, 0x10008}}
	for c in scalars {
		fn, entry := memory_function(t, c.type)
		slot := stack_slot(fn, entry.control, 16, 8)
		pointer := ptr_offset(fn, slot, 1)
		stored := store(fn, entry.control, entry.memory, pointer, edge_constant(fn, c.type, c.bits), 0)
		loaded := load(fn, entry.control, stored, pointer, c.type, 0)
		result := memory_finish(t, &module, fn, entry.control, stored, loaded)
		testing.expectf(t, result.outcome == .Value && result.value == c.bits, "%v: got %v %x", c.type, result.outcome, result.value)
	}

	{
		fn, entry := memory_function(t, .I64)
		table := symbol_addr(fn, Symbol_Ref{space = .Global, index = 0})
		pointer := load(fn, entry.control, entry.memory, ptr_offset(fn, table, 8), .Ptr, 3)
		target_value := load(fn, entry.control, entry.memory, pointer, .I64, 3)
		local := load(fn, entry.control, entry.memory, tls_addr(fn, Symbol_Ref{space = .Global, index = 2}), .I64, 3)
		result := memory_finish(t, &module, fn, entry.control, entry.memory, binary(fn, .Add, target_value, local))
		testing.expectf(t, result.outcome == .Value && result.value == 0x12A, "relocation and tls: got %v %x", result.outcome, result.value)
	}

	{
		fn, entry := memory_function(t, .I64)
		slot := stack_slot(fn, entry.control, 16, 8)
		stored := store(fn, entry.control, entry.memory, slot, const_int(fn, .I64, 0x0807060504030201), 3)
		copied := add_node(fn, .Mem_Copy, .Memory, {entry.control, stored, ptr_offset(fn, slot, 2), slot, const_int(fn, .I64, 6)})
		set := add_node(fn, .Mem_Set, .Memory, {entry.control, copied, ptr_offset(fn, slot, 6), const_int(fn, .I8, 0xFF), const_int(fn, .I64, 2)})
		value := load(fn, entry.control, set, slot, .I64, 3)
		result := memory_finish(t, &module, fn, entry.control, set, value)
		testing.expectf(t, result.outcome == .Value && result.value == 0xFFFF040302010201, "copy and set: got %v %x", result.outcome, result.value)
	}
}

@(test)
interp_store_waits_for_loads :: proc(t: ^testing.T) {
	module: Module
	testing.expect_value(t, module_init(&module), nil)
	defer module_destroy(&module)

	fn, entry := memory_function(t, .I64)
	slot := stack_slot(fn, entry.control, 8, 8)
	stored := store(fn, entry.control, entry.memory, slot, const_int(fn, .I64, 1), 3)
	loaded := load(fn, entry.control, entry.memory, slot, .I64, 3)
	result := memory_finish(t, &module, fn, entry.control, stored, loaded)
	testing.expectf(t, result.outcome == .Value && result.value == 0, "load before store: got %v %x", result.outcome, result.value)
}

@(private = "file")
call_function :: proc(t: ^testing.T, module: ^Module, signature: Signature) -> (fn: ^Function, entry: Start_Nodes, index: u32) {
	err: runtime.Allocator_Error
	fn, err = function_make(context.allocator, Function_Id(len(module.functions)), "main.call", 0)
	testing.expect_value(t, err, nil)
	add_signature(fn, signature)
	entry = start(fn)
	index = u32(len(module.functions))
	_, append_err := append(&module.functions, fn)
	testing.expect_value(t, append_err, nil)
	return
}

@(private = "file")
call_results :: proc(fn: ^Function, call_node: Node_Id, value_type: Value_Type) -> (memory, value: Node_Id) {
	memory = add_node(fn, .Proj, .Memory, {call_node}, {index = 0})
	value = add_node(fn, .Proj, value_type, {call_node}, {index = 1})
	return
}

@(test)
interp_calls :: proc(t: ^testing.T) {
	module: Module
	testing.expect_value(t, module_init(&module), nil)
	defer module_destroy(&module)

	fib, fib_entry, fib_index := call_function(t, &module, Signature{cc = .C, params = {{type = .I64}}, results = {{type = .I64}}})
	n := fib_entry.params[0]
	one, two := const_int(fib, .I64, 1), const_int(fib, .I64, 2)
	small, large := if_(fib, fib_entry.control, compare(fib, .SLt, n, two))
	ret(fib, small, fib_entry.memory, n)
	fib_callee := symbol_addr(fib, Symbol_Ref{space = .Function, index = fib_index})
	first_call := call(fib, large, fib_entry.memory, fib_callee, 0, {binary(fib, .Sub, n, one)})
	first_memory, first_value := call_results(fib, first_call, .I64)
	second_call := call(fib, large, first_memory, fib_callee, 0, {binary(fib, .Sub, n, two)})
	second_memory, second_value := call_results(fib, second_call, .I64)
	ret(fib, large, second_memory, binary(fib, .Add, first_value, second_value))
	testing.expect_value(t, function_finish(fib), nil)

	split, split_entry, split_index := call_function(
		t,
		&module,
		Signature{cc = .Odin, params = {{type = .I64}, {type = .Ptr}, {type = .Ptr, attr = .Context}}, results = {{type = .I64}}},
	)
	split_n, split_out := split_entry.params[0], split_entry.params[1]
	stored := store(split, split_entry.control, split_entry.memory, split_out, binary(split, .Add, split_n, split_n), 3)
	ret(split, split_entry.control, stored, binary(split, .Add, split_n, const_int(split, .I64, 1)))
	testing.expect_value(t, function_finish(split), nil)

	indirect, indirect_entry, indirect_index := call_function(
		t,
		&module,
		Signature{cc = .Odin, params = {{type = .Ptr, attr = .Indirect}, {type = .Ptr, attr = .Context}}, results = {{type = .I64}}},
	)
	field := load(indirect, indirect_entry.control, indirect_entry.memory, indirect_entry.params[0], .I64, 3)
	ret(indirect, indirect_entry.control, indirect_entry.memory, field)
	testing.expect_value(t, function_finish(indirect), nil)

	caller, caller_entry, _ := call_function(t, &module, Signature{cc = .C, results = {{type = .I64}}})
	fib_signature := add_signature(caller, Signature{cc = .C, params = {{type = .I64}}, results = {{type = .I64}}})
	indirect_signature := add_signature(
		caller,
		Signature{cc = .Odin, params = {{type = .Ptr, attr = .Indirect}, {type = .Ptr, attr = .Context}}, results = {{type = .I64}}},
	)
	split_signature := add_signature(
		caller,
		Signature{cc = .Odin, params = {{type = .I64}, {type = .Ptr}, {type = .Ptr, attr = .Context}}, results = {{type = .I64}}},
	)
	control := caller_entry.control
	slot := stack_slot(caller, control, 8, 8)
	out := stack_slot(caller, control, 8, 8)
	fib_call := call(
		caller,
		control,
		caller_entry.memory,
		symbol_addr(caller, Symbol_Ref{space = .Function, index = fib_index}),
		fib_signature,
		{const_int(caller, .I64, 10)},
	)
	fib_memory, fib_value := call_results(caller, fib_call, .I64)
	stored_field := store(caller, control, fib_memory, slot, const_int(caller, .I64, 77), 3)
	indirect_call := call(
		caller,
		control,
		stored_field,
		symbol_addr(caller, Symbol_Ref{space = .Function, index = indirect_index}),
		indirect_signature,
		{slot, slot},
	)
	indirect_memory, indirect_value := call_results(caller, indirect_call, .I64)
	split_call := call(
		caller,
		control,
		indirect_memory,
		symbol_addr(caller, Symbol_Ref{space = .Function, index = split_index}),
		split_signature,
		{const_int(caller, .I64, 5), out, slot},
	)
	split_memory, split_value := call_results(caller, split_call, .I64)
	split_stored := load(caller, control, split_memory, out, .I64, 3)
	total := binary(caller, .Add, binary(caller, .Add, fib_value, indirect_value), binary(caller, .Add, split_value, split_stored))
	ret(caller, control, split_memory, total)
	testing.expect_value(t, function_finish(caller), nil)

	result, err := interp_run(&module, caller, nil, 100_000, context.allocator)
	testing.expect_value(t, err, nil)
	testing.expectf(t, result.outcome == .Value && result.value == 148, "calls: got %v %v", result.outcome, result.value)
}

@(private = "file")
atomic_op :: proc(fn: ^Function, kind: Node_Kind, inputs: []Node_Id, access: Access_Info) -> Node_Id {
	return add_node(fn, kind, .Tuple, inputs, {access = access})
}

@(private = "file")
widen_to_i64 :: proc(fn: ^Function, value: Node_Id) -> Node_Id {
	if fn.nodes.type[value] == .I64 {
		return value
	}
	return convert(fn, .Zext, value, .I64)
}

@(test)
interp_atomics_and_target_ops :: proc(t: ^testing.T) {
	module: Module
	testing.expect_value(t, module_init(&module), nil)
	defer module_destroy(&module)

	fn, entry := memory_function(t, .I64)
	control := entry.control
	slot := stack_slot(fn, control, 4, 4)
	m0 := store(fn, control, entry.memory, slot, const_int(fn, .I32, 5), 2)
	access := Access_Info {
		align_log2 = 2,
		order      = .Seq_Cst,
		rmw        = .Add,
	}
	add := atomic_op(fn, .Atomic_Rmw, {control, m0, slot, const_int(fn, .I32, 3)}, access)
	m1, old_add := call_results(fn, add, .I32)
	access.rmw = .Xchg
	xchg := atomic_op(fn, .Atomic_Rmw, {control, m1, slot, const_int(fn, .I32, 0x20)}, access)
	m2, old_xchg := call_results(fn, xchg, .I32)
	access.failure_order = .Seq_Cst
	hit := atomic_op(fn, .Atomic_Cas, {control, m2, slot, const_int(fn, .I32, 0x20), const_int(fn, .I32, 0x40)}, access)
	m3, old_hit := call_results(fn, hit, .I32)
	hit_success := add_node(fn, .Proj, .Bool, {hit}, {index = 2})
	miss := atomic_op(fn, .Atomic_Cas, {control, m3, slot, const_int(fn, .I32, 0x20), const_int(fn, .I32, 0x50)}, access)
	m4, old_miss := call_results(fn, miss, .I32)
	miss_success := add_node(fn, .Proj, .Bool, {miss}, {index = 2})
	access.rmw = .Nand
	nand := atomic_op(fn, .Atomic_Rmw, {control, m4, slot, const_int(fn, .I32, 0xFF)}, access)
	m5, old_nand := call_results(fn, nand, .I32)
	final := load(fn, control, m5, slot, .I32, 2)
	cpuid := add_node(fn, .Target_Op, .Tuple, {control, m5, const_int(fn, .I32, 0), const_int(fn, .I32, 0)}, {index = u32(Target_Op.Cpuid)})
	m6 := add_node(fn, .Proj, .Memory, {cpuid}, {index = 0})
	cpuid_eax := add_node(fn, .Proj, .I32, {cpuid}, {index = 1})
	xgetbv := add_node(fn, .Target_Op, .Tuple, {control, m6, const_int(fn, .I32, 0)}, {index = u32(Target_Op.Xgetbv)})
	m7 := add_node(fn, .Proj, .Memory, {xgetbv}, {index = 0})
	xgetbv_eax := add_node(fn, .Proj, .I32, {xgetbv}, {index = 1})
	rdtsc := add_node(fn, .Target_Op, .Tuple, {control, m7}, {index = u32(Target_Op.Rdtsc)})
	m8 := add_node(fn, .Proj, .Memory, {rdtsc}, {index = 0})
	rdtsc_value := add_node(fn, .Proj, .I64, {rdtsc}, {index = 1})

	terms := [?]Node_Id{old_add, old_xchg, old_hit, hit_success, old_miss, miss_success, old_nand, final, cpuid_eax, xgetbv_eax, rdtsc_value}
	total := widen_to_i64(fn, terms[0])
	for term in terms[1:] {
		total = binary(fn, .Add, total, widen_to_i64(fn, term))
	}
	result := memory_finish(t, &module, fn, control, m8, total)
	testing.expectf(t, result.outcome == .Value && result.value == 4294967410, "atomics and target ops: got %v %v", result.outcome, result.value)
}
