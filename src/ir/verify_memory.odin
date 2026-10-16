package ir

// M1-M5: path-consistent memory states (section 9). Every reachable block has an entry state;
// its state producers must form one chain from it; the block's exit state is the end of that
// chain; merges and branch projections must receive the exit states of their predecessors.

@(private = "file")
is_tuple_producer :: proc(kind: Node_Kind) -> bool {
	#partial switch kind {
	case .Call, .Syscall, .Target_Op, .Load_Ordered, .Atomic_Rmw, .Atomic_Cas:
		return true
	}
	return false
}

@(private = "file")
is_state_producer :: proc(kind: Node_Kind) -> bool {
	#partial switch kind {
	case .Store, .Mem_Copy, .Mem_Set, .Fence:
		return true
	}
	return is_tuple_producer(kind)
}

@(private = "file")
has_memory_operand :: proc(kind: Node_Kind) -> bool {
	#partial switch kind {
	case .Load, .Return, .Unreachable, .Trap:
		return true
	}
	return is_state_producer(kind)
}

check_memory :: proc(v: ^Verifier, cfg: Cfg) {
	check_memory_values(v)
	if len(cfg.heads) > 0 {
		check_block_states(v, cfg)
	}
}

// M1 and M2.
@(private = "file")
check_memory_values :: proc(v: ^Verifier) {
	fn := v.fn
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		if kind == .Removed {
			continue
		}
		if fn.nodes.type[id] == .Memory {
			valid := is_state_producer(kind) || kind == .Phi
			if kind == .Proj {
				tuple_kind := fn.nodes.kind[node_input(fn, id, 0)]
				member := fn.nodes.data[id].index
				valid = (tuple_kind == .Start && member == 1) || (is_tuple_producer(tuple_kind) && member == 0)
			}
			if !valid {
				report_error(v, id, NODE_NONE, .Bad_Memory_Producer)
			}
		}

		if kind != .Phi {
			operands := 0
			for input in node_inputs(fn, id) {
				operands += int(node_type(v, input) == .Memory)
			}
			if operands != int(has_memory_operand(kind)) {
				report_error(v, id, NODE_NONE, .Bad_Memory_Operand_Count)
			}
		}
	}
}

// M3, M4 and M5.
@(private = "file")
check_block_states :: proc(v: ^Verifier, cfg: Cfg) {
	fn := v.fn
	node_count := len(fn.nodes)
	block_count := len(cfg.heads)
	scratch := v.scratch

	state_out := make([]Node_Id, node_count, scratch)
	taker := make([]Node_Id, node_count, scratch)
	mark := make([]u32, node_count, scratch)
	exit_state := make([]Node_Id, block_count, scratch)
	member_first := make([]u32, block_count + 1, scratch)
	for index in 1 ..< node_count {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		if kind == .Proj && fn.nodes.type[id] == .Memory && fn.nodes.data[id].index == 0 {
			state_out[node_input(fn, id, 0)] = id
		}
		if is_state_producer(kind) || kind == .Load {
			if block := block_of_node(cfg, fn, id); block != BLOCK_NONE {
				member_first[block + 1] += 1
			}
		}
	}
	for block in 0 ..< block_count {
		member_first[block + 1] += member_first[block]
	}
	members := make([]Node_Id, member_first[block_count], scratch)
	cursor := make([]u32, block_count, scratch)
	for index in 1 ..< node_count {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		if is_state_producer(kind) || kind == .Load {
			if block := block_of_node(cfg, fn, id); block != BLOCK_NONE {
				members[member_first[block] + cursor[block]] = id
				cursor[block] += 1
			}
		}
	}

	for block in 0 ..< block_count {
		stamp := u32(block) + 1
		entry := entry_state(v, cfg, exit_state, block)
		mark[entry] = stamp
		block_members := members[member_first[block]:member_first[block + 1]]

		producer_count := 0
		for member in block_members {
			if fn.nodes.kind[member] == .Load {
				continue
			}
			producer_count += 1
			consumed := node_input(fn, member, 1)
			if taker[consumed] != NODE_NONE {
				report_error(v, member, taker[consumed], .Bad_Block_Chain)
			} else {
				taker[consumed] = member
			}
		}

		current := entry
		for _ in 0 ..< producer_count {
			producer := taker[current]
			if producer == NODE_NONE {
				break
			}
			current = state_out[producer] if is_tuple_producer(fn.nodes.kind[producer]) else producer
			mark[current] = stamp
		}

		for member in block_members {
			consumed := node_input(fn, member, 1)
			if fn.nodes.kind[member] == .Load {
				if mark[consumed] != stamp {
					report_error(v, member, consumed, .Stale_Load)
				}
			} else {
				if mark[consumed] != stamp {
					report_error(v, member, consumed, .Bad_Block_Chain)
				}
				taker[consumed] = NODE_NONE
			}
		}

		exit := cfg.exits[block]
		if cfg.exit_counts[block] == 1 && exit != NODE_NONE {
			#partial switch fn.nodes.kind[exit] {
			case .Return, .Unreachable, .Trap:
				if node_input(fn, exit, 1) != current {
					report_error(v, exit, node_input(fn, exit, 1), .Bad_Block_Chain)
				}
			}
		}
		exit_state[block] = current
	}

	for block in 0 ..< block_count {
		head := cfg.heads[block]
		phi := v.memory_phi[head]
		if (fn.nodes.kind[head] != .Region && fn.nodes.kind[head] != .Loop) || phi == NODE_NONE {
			continue
		}
		if fn.nodes.input_count[phi] != fn.nodes.input_count[head] + 1 {
			continue
		}
		for slot in 0 ..< int(fn.nodes.input_count[head]) {
			predecessor := node_input(fn, head, slot)
			if int(predecessor) < len(cfg.block_of) && cfg.block_of[predecessor] != BLOCK_NONE {
				if exit_state[cfg.block_of[predecessor]] != node_input(fn, phi, slot + 1) {
					report_error(v, phi, node_input(fn, phi, slot + 1), .Bad_Block_Entry_State)
				}
			}
		}
	}
}

// The state a block starts with. A merge uses its memory phi; without one, every
// predecessor must agree. A branch projection continues its source block's exit state.
@(private = "file")
entry_state :: proc(v: ^Verifier, cfg: Cfg, exit_state: []Node_Id, block: int) -> Node_Id {
	fn := v.fn
	head := cfg.heads[block]
	if block == 0 {
		if v.start_state == NODE_NONE {
			report_error(v, head, NODE_NONE, .Bad_Block_Entry_State)
		}
		return v.start_state
	}

	#partial switch fn.nodes.kind[head] {
	case .Region, .Loop:
		if phi := v.memory_phi[head]; phi != NODE_NONE {
			return phi
		}
		common := NODE_NONE
		for predecessor, index in block_preds(cfg, Block_Id(block)) {
			if int(predecessor) >= block {
				continue
			}
			state := exit_state[predecessor]
			if index == 0 {
				common = state
			} else if state != common {
				report_error(v, head, state, .Bad_Block_Entry_State)
			}
		}
		return common
	case .Proj:
		for predecessor in block_preds(cfg, Block_Id(block)) {
			if int(predecessor) < block {
				return exit_state[predecessor]
			}
		}
	}
	return NODE_NONE
}
