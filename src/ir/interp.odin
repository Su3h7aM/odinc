package ir

import "base:runtime"

Interp_Outcome :: enum u8 {
	Value,
	Trap,
	Unreachable,
	Arith_Trap,
	Out_of_Fuel,
	Fault, // `value` holds the faulting address
	Unsupported,
}

Interp_Result :: struct {
	outcome: Interp_Outcome,
	value:   u64,
	node:    Node_Id,
}

Interp_State :: struct {
	module:           ^Module,
	fn:               ^Function,
	uses:             Use_Table,
	arguments:        []u64,
	values:           []u64,
	stamps:           []u64,
	scratch:          []u64,
	pending:          []Node_Id,
	memory:           []u8,
	global_addresses: []u64,
	blob_addresses:   []u64,
	slot_addresses:   []u64,
	generation:       u64,
	fuel:             int,
	result:           Interp_Result,
}

interp_run :: proc(
	module: ^Module,
	fn: ^Function,
	arguments: []u64,
	fuel: int,
	allocator: runtime.Allocator,
) -> (
	result: Interp_Result,
	err: runtime.Allocator_Error,
) {
	uses := uses_build(fn, allocator) or_return
	defer use_table_destroy(&uses, allocator)
	phi_count := 0
	for id in 1 ..< len(fn.nodes) {
		if fn.nodes.kind[id] == .Phi {
			phi_count += 1
		}
	}
	s := Interp_State {
		module     = module,
		fn         = fn,
		uses       = uses,
		arguments  = arguments,
		fuel       = fuel,
		generation = 1,
	}
	s.values = make([]u64, len(fn.nodes), allocator) or_return
	defer delete(s.values, allocator)
	s.stamps = make([]u64, len(fn.nodes), allocator) or_return
	defer delete(s.stamps, allocator)
	s.scratch = make([]u64, phi_count, allocator) or_return
	defer delete(s.scratch, allocator)
	s.pending = make([]Node_Id, len(fn.nodes), allocator) or_return
	defer delete(s.pending, allocator)
	s.global_addresses = make([]u64, len(module.globals), allocator) or_return
	defer delete(s.global_addresses, allocator)
	s.blob_addresses = make([]u64, len(fn.blobs), allocator) or_return
	defer delete(s.blob_addresses, allocator)
	s.slot_addresses = make([]u64, len(fn.nodes), allocator) or_return
	defer delete(s.slot_addresses, allocator)
	s.memory = make([]u8, interp_layout(&s), allocator) or_return
	defer delete(s.memory, allocator)
	if !interp_initialize(&s) {
		return s.result, nil
	}
	return interp_walk(&s), nil
}

interp_fail :: proc(s: ^Interp_State, outcome: Interp_Outcome, node: Node_Id) {
	s.result = Interp_Result {
		outcome = outcome,
		node    = node,
	}
}

// Pinned nodes read the value stored when the walk executed them; Stack_Slot is a constant address.
interp_evaluate :: proc(s: ^Interp_State, id: Node_Id) -> (u64, bool) {
	kind := s.fn.nodes.kind[id]
	if kind == .Phi {
		return s.values[id], true
	}
	if is_pinned(kind) && kind != .Stack_Slot {
		if s.stamps[id] == 0 {
			interp_fail(s, .Unsupported, id)
			return 0, false
		}
		return s.values[id], true
	}
	if s.stamps[id] == s.generation {
		return s.values[id], true
	}
	value, ok := interp_compute(s, id)
	if ok {
		s.values[id] = value
		s.stamps[id] = s.generation
	}
	return value, ok
}

interp_walk :: proc(s: ^Interp_State) -> Interp_Result {
	head, ok := interp_start_head(s)
	if !ok {
		return s.result
	}
	for {
		if s.fuel == 0 {
			return Interp_Result{outcome = .Out_of_Fuel, node = head}
		}
		s.fuel -= 1
		next, block_ok := interp_block(s, head)
		if !block_ok || next == NODE_NONE {
			return s.result
		}
		head = next
	}
}

@(private = "file")
interp_start_head :: proc(s: ^Interp_State) -> (Node_Id, bool) {
	for use in uses_of(s.uses, s.fn.start) {
		if s.fn.nodes.kind[use.user] == .Proj && s.fn.nodes.data[use.user].index == 0 {
			return use.user, true
		}
	}
	interp_fail(s, .Unsupported, s.fn.start)
	return NODE_NONE, false
}

// Runs the pinned nodes of one block, then its exit. Returns the next head, or `NODE_NONE` once
// `s.result` holds the outcome of the function.
@(private = "file")
interp_block :: proc(s: ^Interp_State, head: Node_Id) -> (Node_Id, bool) {
	fn := s.fn
	exit: Use
	exit_count := 0
	pending_count := 0
	for use in uses_of(s.uses, head) {
		#partial switch fn.nodes.kind[use.user] {
		case .SDiv, .UDiv, .SRem, .URem, .Load, .Load_Ordered, .Store, .Mem_Copy, .Mem_Set, .Fence:
			s.pending[pending_count] = use.user
			pending_count += 1
		case .If, .Switch, .Return, .Unreachable, .Trap, .Region, .Loop:
			exit = use
			exit_count += 1
		case .Phi, .Stack_Slot:
		case:
			interp_fail(s, .Unsupported, use.user)
			return NODE_NONE, false
		}
	}
	if exit_count != 1 {
		interp_fail(s, .Unsupported, head)
		return NODE_NONE, false
	}
	if !interp_run_pending(s, s.pending[:pending_count]) {
		return NODE_NONE, false
	}
	#partial switch fn.nodes.kind[exit.user] {
	case .Region, .Loop:
		return interp_jump(s, exit.user, exit.slot)
	case .If:
		condition, ok := interp_evaluate(s, node_input(fn, exit.user, 1))
		if !ok {
			return NODE_NONE, false
		}
		arm: u32 = 0 if condition & 1 == 1 else 1
		return interp_projection_user(s, exit.user, arm)
	case .Switch:
		value, ok := interp_evaluate(s, node_input(fn, exit.user, 1))
		if !ok {
			return NODE_NONE, false
		}
		value_type := fn.nodes.type[node_input(fn, exit.user, 1)]
		table := fn.tables[fn.nodes.data[exit.user].index]
		arm := u32(len(table))
		for case_value, index in table {
			if interp_canonical(value_type, u64(case_value)) == value {
				arm = u32(index)
				break
			}
		}
		return interp_projection_user(s, exit.user, arm)
	case .Return:
		return NODE_NONE, interp_return(s, exit.user)
	case .Unreachable:
		interp_fail(s, .Unreachable, exit.user)
	case .Trap:
		interp_fail(s, .Trap, exit.user)
	}
	return NODE_NONE, true
}

// Executes each pending node once its memory input is taken and no earlier-id rule is broken: a state
// producer waits for the plain loads of its state (doc section 7, rule 3). Ties go to the lower id.
@(private = "file")
interp_run_pending :: proc(s: ^Interp_State, pending: []Node_Id) -> bool {
	remaining := len(pending)
	for remaining > 0 {
		progressed := false
		for id, index in pending {
			if id == NODE_NONE || !interp_memory_ready(s, pending, id) {
				continue
			}
			if !interp_execute_pinned(s, id) {
				return false
			}
			pending[index] = NODE_NONE
			remaining -= 1
			progressed = true
		}
		if !progressed {
			for id in pending {
				if id != NODE_NONE {
					interp_fail(s, .Unsupported, id)
					break
				}
			}
			return false
		}
	}
	return true
}

@(private = "file")
interp_execute_pinned :: proc(s: ^Interp_State, id: Node_Id) -> bool {
	value: u64
	ok: bool
	#partial switch s.fn.nodes.kind[id] {
	case .SDiv, .UDiv, .SRem, .URem:
		value, ok = interp_divide(s, id)
	case:
		value, ok = interp_memory_execute(s, id)
	}
	if !ok {
		return false
	}
	s.values[id] = value
	s.stamps[id] = s.generation
	s.generation += 1
	return true
}

@(private = "file")
interp_memory_ready :: proc(s: ^Interp_State, pending: []Node_Id, id: Node_Id) -> bool {
	kind := s.fn.nodes.kind[id]
	if !interp_takes_memory(kind) {
		return true
	}
	state := interp_memory_source(s.fn, node_input(s.fn, id, 1))
	if interp_pending_contains(pending, state) {
		return false
	}
	if interp_produces_memory(kind) {
		for other in pending {
			if other != NODE_NONE && other != id && s.fn.nodes.kind[other] == .Load && interp_memory_source(s.fn, node_input(s.fn, other, 1)) == state {
				return false
			}
		}
	}
	return true
}

@(private = "file")
interp_takes_memory :: proc(kind: Node_Kind) -> bool {
	#partial switch kind {
	case .Load, .Load_Ordered, .Store, .Mem_Copy, .Mem_Set, .Fence:
		return true
	}
	return false
}

@(private = "file")
interp_produces_memory :: proc(kind: Node_Kind) -> bool {
	#partial switch kind {
	case .Load_Ordered, .Store, .Mem_Copy, .Mem_Set, .Fence:
		return true
	}
	return false
}

// A projection of a pinned producer stands for that producer's state.
@(private = "file")
interp_memory_source :: proc(fn: ^Function, id: Node_Id) -> Node_Id {
	if fn.nodes.kind[id] == .Proj && is_pinned(fn.nodes.kind[node_input(fn, id, 0)]) {
		return node_input(fn, id, 0)
	}
	return id
}

@(private = "file")
interp_pending_contains :: proc(pending: []Node_Id, id: Node_Id) -> bool {
	for candidate in pending {
		if candidate == id {
			return true
		}
	}
	return false
}

@(private = "file")
interp_projection_user :: proc(s: ^Interp_State, source: Node_Id, index: u32) -> (Node_Id, bool) {
	for use in uses_of(s.uses, source) {
		if s.fn.nodes.kind[use.user] == .Proj && use.slot == 0 && s.fn.nodes.data[use.user].index == index {
			return use.user, true
		}
	}
	interp_fail(s, .Unsupported, source)
	return NODE_NONE, false
}

@(private = "file")
interp_return :: proc(s: ^Interp_State, node: Node_Id) -> bool {
	results := node_inputs(s.fn, node)[2:]
	switch len(results) {
	case 0:
		s.result = Interp_Result {
			outcome = .Value,
			node    = node,
		}
	case 1:
		value, ok := interp_evaluate(s, results[0])
		if !ok {
			return false
		}
		s.result = Interp_Result {
			outcome = .Value,
			value   = value,
			node    = node,
		}
	case:
		interp_fail(s, .Unsupported, node)
		return false
	}
	return true
}

// Region and loop phis read their arm before any phi is written; the generation bump invalidates pure values.
@(private = "file")
interp_jump :: proc(s: ^Interp_State, target: Node_Id, arm: u16) -> (Node_Id, bool) {
	count := 0
	for use in uses_of(s.uses, target) {
		if s.fn.nodes.kind[use.user] != .Phi || use.slot != 0 {
			continue
		}
		value, ok := interp_evaluate(s, node_input(s.fn, use.user, int(arm) + 1))
		if !ok {
			return NODE_NONE, false
		}
		s.scratch[count] = value
		count += 1
	}
	count = 0
	for use in uses_of(s.uses, target) {
		if s.fn.nodes.kind[use.user] != .Phi || use.slot != 0 {
			continue
		}
		s.values[use.user] = s.scratch[count]
		count += 1
	}
	s.generation += 1
	return target, true
}
