package ir

@(private = "file")
block_at :: proc(cfg: Cfg, id: Node_Id) -> Block_Id {
	return cfg.block_of[id] if int(id) < len(cfg.block_of) else BLOCK_NONE
}

// C4 and C5.
check_loops :: proc(v: ^Verifier, cfg: Cfg) {
	fn := v.fn
	for loop in cfg.loops {
		head := cfg.heads[loop.header]
		entry := block_at(cfg, node_input(fn, head, 0))
		if loop.back_edge_source == BLOCK_NONE || !dominates(cfg, loop.header, loop.back_edge_source) {
			report_error(v, head, node_input(fn, head, 1), .Bad_Loop_Dominance)
		}
		if entry != BLOCK_NONE && dominates(cfg, loop.header, entry) {
			report_error(v, head, node_input(fn, head, 0), .Bad_Loop_Dominance)
		}
	}

	// An edge to an earlier or equal block in reverse post-order is a retreating edge of the DFS.
	for block in 0 ..< len(cfg.heads) {
		source := cfg.heads[block]
		for target in block_succs(cfg, Block_Id(block)) {
			if int(target) > block {
				continue
			}
			target_head := cfg.heads[target]
			is_back_edge := fn.nodes.kind[target_head] == .Loop && node_input(fn, target_head, 1) == source
			if !is_back_edge {
				report_error(v, source, target_head, .Irreducible)
			}
		}
	}
}

// C6 and the memory phi lookup the memory rules use.
check_phis :: proc(v: ^Verifier) {
	fn := v.fn
	memory_phi, err := make([]Node_Id, len(fn.nodes), v.scratch)
	if err != nil {
		v.failure = err
		return
	}
	v.memory_phi = memory_phi
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		if fn.nodes.kind[id] != .Phi || fn.nodes.type[id] != .Memory {
			continue
		}
		merge := node_input(fn, id, 0)
		if memory_phi[merge] != NODE_NONE {
			report_error(v, id, memory_phi[merge], .Bad_Phi)
		} else {
			memory_phi[merge] = id
		}
	}
	for index in 1 ..< len(fn.nodes) {
		if fn.nodes.kind[index] == .Loop && memory_phi[index] == NODE_NONE {
			report_error(v, Node_Id(index), NODE_NONE, .Bad_Phi)
		}
	}
}

// D2: pinned nodes take control in slot 0, pure nodes take none.
check_control_classes :: proc(v: ^Verifier) {
	fn := v.fn
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		if is_pinned(kind) && node_type(v, node_input(fn, id, 0)) != .Control {
			report_error(v, id, node_input(fn, id, 0), .Bad_Control_Class)
		} else if is_pure(kind) {
			for input in node_inputs(fn, id) {
				if node_type(v, input) == .Control {
					report_error(v, id, input, .Bad_Control_Class)
				}
			}
		}
	}
}

@(private = "file")
Placement :: struct {
	block:   []Block_Id,
	state:   []Placement_State,
	pending: [dynamic]Node_Id,
}

@(private = "file")
Placement_State :: enum u8 {
	Unvisited,
	Visiting,
	Done,
}

// D1: every input of a pinned node, and every input of a phi on its edge, is available in a
// block that dominates the use block.
check_placement :: proc(v: ^Verifier, cfg: Cfg) {
	fn := v.fn
	if len(cfg.heads) == 0 {
		return
	}
	placement := Placement {
		block   = make([]Block_Id, len(fn.nodes), v.scratch),
		state   = make([]Placement_State, len(fn.nodes), v.scratch),
		pending = make([dynamic]Node_Id, v.scratch),
	}
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		if is_pinned(kind) {
			use_block := block_of_node(cfg, fn, id)
			if use_block == BLOCK_NONE {
				continue
			}
			for input in node_inputs(fn, id)[1:] {
				check_available(v, cfg, &placement, id, input, use_block)
			}
		} else if kind == .Phi {
			merge := node_input(fn, id, 0)
			if (fn.nodes.kind[merge] != .Region && fn.nodes.kind[merge] != .Loop) || fn.nodes.input_count[merge] + 1 != fn.nodes.input_count[id] {
				continue
			}
			for value, slot in node_inputs(fn, id)[1:] {
				use_block := block_at(cfg, node_input(fn, merge, slot))
				if use_block != BLOCK_NONE {
					check_available(v, cfg, &placement, id, value, use_block)
				}
			}
		}
	}
}

@(private = "file")
check_available :: proc(v: ^Verifier, cfg: Cfg, placement: ^Placement, user, input: Node_Id, use_block: Block_Id) {
	available := earliest_block(v, cfg, placement, input)
	if available != BLOCK_NONE && !dominates(cfg, available, use_block) {
		report_error(v, user, input, .Unschedulable_Input)
	}
}

// The first block in which a value can be computed. Nodes bound to a block (pinned nodes,
// phis, heads, projections) have it; a pure node's is the deepest block of its inputs, which
// must all dominate that block; constants and addresses belong to the entry. Unknown
// (unreachable) blocks are `BLOCK_NONE`.
@(private = "file")
earliest_block :: proc(v: ^Verifier, cfg: Cfg, placement: ^Placement, root: Node_Id) -> Block_Id {
	fn := v.fn
	clear(&placement.pending)
	append(&placement.pending, root)
	for len(placement.pending) > 0 {
		id := placement.pending[len(placement.pending) - 1]
		if placement.state[id] == .Done {
			pop(&placement.pending)
			continue
		}
		block, is_bound := bound_block(cfg, fn, id)
		if is_bound {
			placement.block[id] = block
			placement.state[id] = .Done
			pop(&placement.pending)
			continue
		}

		placement.state[id] = .Visiting
		descended := false
		for input in node_inputs(fn, id) {
			if placement.state[input] == .Unvisited {
				append(&placement.pending, input)
				descended = true
			}
		}
		if descended {
			continue
		}

		deepest := BLOCK_NONE
		for input in node_inputs(fn, id) {
			input_block := placement.block[input] if placement.state[input] == .Done else BLOCK_NONE
			if input_block != BLOCK_NONE && (deepest == BLOCK_NONE || input_block > deepest) {
				deepest = input_block
			}
		}
		for input in node_inputs(fn, id) {
			input_block := placement.block[input] if placement.state[input] == .Done else BLOCK_NONE
			if input_block != BLOCK_NONE && !dominates(cfg, input_block, deepest) {
				report_error(v, id, input, .Unschedulable_Input)
			}
		}
		placement.block[id] = deepest
		placement.state[id] = .Done
		pop(&placement.pending)
	}
	return placement.block[root]
}

// Whether `id` has its block without looking at its inputs.
@(private = "file")
bound_block :: proc(cfg: Cfg, fn: ^Function, id: Node_Id) -> (block: Block_Id, bound: bool) {
	kind := fn.nodes.kind[id]
	switch {
	case kind == .Start:
		return 0, true
	case kind == .Phi || is_pinned(kind):
		return block_of_node(cfg, fn, id), true
	case kind == .Region || kind == .Loop:
		return block_at(cfg, id), true
	case kind == .Proj:
		if is_block_head(fn, id) {
			return block_at(cfg, id), true
		}
		tuple := node_input(fn, id, 0)
		if fn.nodes.kind[tuple] == .Start {
			return 0, true
		}
		return block_of_node(cfg, fn, tuple), true
	case is_pure(kind):
		return 0, fn.nodes.input_count[id] == 0
	}
	return BLOCK_NONE, true
}
