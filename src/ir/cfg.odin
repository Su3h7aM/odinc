package ir

import "base:runtime"
import "core:slice"

Block_Id :: distinct u32

BLOCK_NONE :: Block_Id(max(u32))

Loop_Index :: distinct u32

LOOP_NONE :: Loop_Index(max(u32))

Loop_Info :: struct {
	header:           Block_Id,
	// `BLOCK_NONE` while the back edge is unsealed or unreachable.
	back_edge_source: Block_Id,
	parent:           Loop_Index,
	depth:            u16,
}

// Blocks are numbered in reverse post-order of the control graph from the entry head, so
// block 0 is the entry and only reachable heads have a block. Predecessors list reachable
// heads only: a `Region`'s predecessor order is its input order, a branch projection has the
// block of its `If`/`Switch`. Successors follow `Proj` index order, or the merges that list
// the head as an input.
Cfg :: struct {
	heads:       []Node_Id,
	exits:       []Node_Id, // the exit node, `NODE_NONE` when the block jumps into a merge
	exit_counts: []u16,
	block_of:    []Block_Id, // by node id; set for reachable heads only
	idoms:       []Block_Id, // `BLOCK_NONE` for the entry
	depths:      []u16,
	loop_of:     []Loop_Index, // innermost loop of each block
	loops:       []Loop_Info, // by header RPO order: an outer loop precedes the loops inside it
	pred_first:  []u32,
	preds:       []Block_Id,
	succ_first:  []u32,
	succs:       []Block_Id,
}

is_block_head :: proc(fn: ^Function, id: Node_Id) -> bool {
	#partial switch fn.nodes.kind[id] {
	case .Region, .Loop:
		return true
	case .Proj:
		if fn.nodes.type[id] != .Control || fn.nodes.input_count[id] != 1 {
			return false
		}
		source := node_input(fn, id, 0)
		#partial switch fn.nodes.kind[source] {
		case .Start, .If, .Switch:
			return true
		}
	}
	return false
}

cfg_destroy :: proc(cfg: ^Cfg, allocator: runtime.Allocator) {
	delete(cfg.heads, allocator)
	delete(cfg.exits, allocator)
	delete(cfg.exit_counts, allocator)
	delete(cfg.block_of, allocator)
	delete(cfg.idoms, allocator)
	delete(cfg.depths, allocator)
	delete(cfg.loop_of, allocator)
	delete(cfg.loops, allocator)
	delete(cfg.pred_first, allocator)
	delete(cfg.preds, allocator)
	delete(cfg.succ_first, allocator)
	delete(cfg.succs, allocator)
	cfg^ = {}
}

block_preds :: proc(cfg: Cfg, block: Block_Id) -> []Block_Id {
	return cfg.preds[cfg.pred_first[block]:cfg.pred_first[int(block) + 1]]
}

block_succs :: proc(cfg: Cfg, block: Block_Id) -> []Block_Id {
	return cfg.succs[cfg.succ_first[block]:cfg.succ_first[int(block) + 1]]
}

// Walks the dominator tree, so it costs the depth of `b`.
dominates :: proc(cfg: Cfg, a, b: Block_Id) -> bool {
	for current := b; current != BLOCK_NONE; current = cfg.idoms[current] {
		if current == a {
			return true
		}
	}
	return false
}

// The block of a head, a pinned node (its control input) or a `Phi` (its merge);
// `BLOCK_NONE` for pure nodes and unreachable code.
block_of_node :: proc(cfg: Cfg, fn: ^Function, id: Node_Id) -> Block_Id {
	if int(id) >= len(cfg.block_of) {
		return BLOCK_NONE
	}
	if is_block_head(fn, id) {
		return cfg.block_of[id]
	}
	if (is_pinned(fn.nodes.kind[id]) || fn.nodes.kind[id] == .Phi) && fn.nodes.input_count[id] > 0 {
		return cfg.block_of[node_input(fn, id, 0)]
	}
	return BLOCK_NONE
}

// Derives the control skeleton from the graph's control nodes: blocks in reverse post-order,
// idoms, depths and loops. `uses` must be a table of `fn`. The caller owns the result, allocated
// with `allocator`; `temp` holds working storage the caller releases.
build_control_skeleton :: proc(
	fn: ^Function,
	allocator: runtime.Allocator,
	uses: Use_Table,
	temp: runtime.Allocator,
) -> (
	cfg: Cfg,
	err: runtime.Allocator_Error,
) {
	node_count := len(fn.nodes)
	entry := entry_head(fn, uses)
	if entry == NODE_NONE {
		return
	}

	succ_start := make([]u32, node_count, temp) or_return
	succ_len := make([]u32, node_count, temp) or_return
	succ_nodes := make([dynamic]Node_Id, temp) or_return
	for id in 1 ..< node_count {
		if is_block_head(fn, Node_Id(id)) {
			succ_start[id] = u32(len(succ_nodes))
			append_head_successors(fn, uses, Node_Id(id), &succ_nodes) or_return
			succ_len[id] = u32(len(succ_nodes)) - succ_start[id]
		}
	}

	Frame :: struct {
		head: Node_Id,
		next: u32,
	}
	visited := make([]bool, node_count, temp) or_return
	postorder := make([dynamic]Node_Id, temp) or_return
	stack := make([dynamic]Frame, temp) or_return
	visited[entry] = true
	append(&stack, Frame{head = entry}) or_return
	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		if top.next < succ_len[top.head] {
			child := succ_nodes[succ_start[top.head] + top.next]
			top.next += 1
			if !visited[child] {
				visited[child] = true
				append(&stack, Frame{head = child}) or_return
			}
		} else {
			append(&postorder, top.head) or_return
			pop(&stack)
		}
	}

	block_count := len(postorder)
	defer if err != nil {
		cfg_destroy(&cfg, allocator)
	}
	cfg.heads = make([]Node_Id, block_count, allocator) or_return
	cfg.exits = make([]Node_Id, block_count, allocator) or_return
	cfg.exit_counts = make([]u16, block_count, allocator) or_return
	cfg.block_of = make([]Block_Id, node_count, allocator) or_return
	cfg.idoms = make([]Block_Id, block_count, allocator) or_return
	cfg.depths = make([]u16, block_count, allocator) or_return
	cfg.loop_of = make([]Loop_Index, block_count, allocator) or_return
	cfg.pred_first = make([]u32, block_count + 1, allocator) or_return
	cfg.succ_first = make([]u32, block_count + 1, allocator) or_return

	slice.fill(cfg.block_of, BLOCK_NONE)
	for head, index in postorder {
		block := block_count - 1 - index
		cfg.heads[block] = head
		cfg.block_of[head] = Block_Id(block)
	}

	succ_list := make([dynamic]Block_Id, temp) or_return
	pred_list := make([dynamic]Block_Id, temp) or_return
	loop_count := 0
	for head, block in cfg.heads {
		cfg.exits[block], cfg.exit_counts[block] = find_exit(fn, uses, head)
		if fn.nodes.kind[head] == .Loop {
			loop_count += 1
		}

		cfg.succ_first[block] = u32(len(succ_list))
		for successor in succ_nodes[succ_start[head]:][:succ_len[head]] {
			append(&succ_list, cfg.block_of[successor]) or_return
		}

		cfg.pred_first[block] = u32(len(pred_list))
		append_head_predecessors(fn, cfg, head, &pred_list) or_return
	}
	cfg.succ_first[block_count] = u32(len(succ_list))
	cfg.pred_first[block_count] = u32(len(pred_list))
	cfg.succs = slice.clone(succ_list[:], allocator) or_return
	cfg.preds = slice.clone(pred_list[:], allocator) or_return

	compute_idoms(&cfg)

	cfg.loops = make([]Loop_Info, loop_count, allocator) or_return
	slice.fill(cfg.loop_of, LOOP_NONE)
	find_loops(fn, &cfg, temp) or_return
	return cfg, nil
}

@(private = "file")
entry_head :: proc(fn: ^Function, uses: Use_Table) -> Node_Id {
	if fn.start == NODE_NONE {
		return NODE_NONE
	}
	for use in uses_of(uses, fn.start) {
		if is_block_head(fn, use.user) {
			return use.user
		}
	}
	return NODE_NONE
}

@(private = "file")
is_exit_kind :: proc(kind: Node_Kind) -> bool {
	#partial switch kind {
	case .If, .Switch, .Return, .Unreachable, .Trap:
		return true
	}
	return false
}

@(private = "file")
find_exit :: proc(fn: ^Function, uses: Use_Table, head: Node_Id) -> (exit: Node_Id, count: u16) {
	for use in uses_of(uses, head) {
		kind := fn.nodes.kind[use.user]
		is_jump := kind == .Region || kind == .Loop
		if is_jump || (is_exit_kind(kind) && use.slot == 0) {
			if !is_jump && exit == NODE_NONE {
				exit = use.user
			}
			count += 1
		}
	}
	return
}

@(private = "file")
append_head_successors :: proc(fn: ^Function, uses: Use_Table, head: Node_Id, out: ^[dynamic]Node_Id) -> runtime.Allocator_Error {
	for use in uses_of(uses, head) {
		kind := fn.nodes.kind[use.user]
		switch {
		case kind == .Region || kind == .Loop:
			append(out, use.user) or_return
		case (kind == .If || kind == .Switch) && use.slot == 0:
			first := len(out)
			for branch_use in uses_of(uses, use.user) {
				if is_block_head(fn, branch_use.user) {
					append(out, branch_use.user) or_return
				}
			}
			slice.sort_by_with_data(out[first:], projection_less, fn)
		}
	}
	return nil
}

@(private = "file")
projection_less :: proc(a, b: Node_Id, data: rawptr) -> bool {
	fn := (^Function)(data)
	index_a, index_b := fn.nodes.data[a].index, fn.nodes.data[b].index
	return index_a < index_b || (index_a == index_b && a < b)
}

@(private = "file")
append_head_predecessors :: proc(fn: ^Function, cfg: Cfg, head: Node_Id, out: ^[dynamic]Block_Id) -> runtime.Allocator_Error {
	#partial switch fn.nodes.kind[head] {
	case .Region, .Loop:
		for input in node_inputs(fn, head) {
			if input != NODE_NONE && cfg.block_of[input] != BLOCK_NONE {
				append(out, cfg.block_of[input]) or_return
			}
		}
	case .Proj:
		exit := node_input(fn, head, 0)
		if kind := fn.nodes.kind[exit]; kind == .If || kind == .Switch {
			control := node_input(fn, exit, 0)
			if cfg.block_of[control] != BLOCK_NONE {
				append(out, cfg.block_of[control]) or_return
			}
		}
	}
	return nil
}

// Cooper, Harvey and Kennedy, "A Simple, Fast Dominance Algorithm", over RPO numbers.
@(private = "file")
compute_idoms :: proc(cfg: ^Cfg) {
	slice.fill(cfg.idoms, BLOCK_NONE)
	if len(cfg.heads) == 0 {
		return
	}
	cfg.idoms[0] = 0
	for changed := true; changed; {
		changed = false
		for block in 1 ..< len(cfg.heads) {
			new_idom := BLOCK_NONE
			for pred in block_preds(cfg^, Block_Id(block)) {
				if cfg.idoms[pred] == BLOCK_NONE {
					continue
				}
				new_idom = pred if new_idom == BLOCK_NONE else common_dominator(cfg^, new_idom, pred)
			}
			if new_idom != cfg.idoms[block] {
				cfg.idoms[block] = new_idom
				changed = true
			}
		}
	}
	cfg.idoms[0] = BLOCK_NONE
}

@(private = "file")
common_dominator :: proc(cfg: Cfg, a, b: Block_Id) -> Block_Id {
	a, b := a, b
	for a != b {
		for a > b {
			a = cfg.idoms[a]
		}
		for b > a {
			b = cfg.idoms[b]
		}
	}
	return a
}

// A loop body is the header plus every block that reaches the back-edge source without
// passing the header (section 5).
@(private = "file")
find_loops :: proc(fn: ^Function, cfg: ^Cfg, temp: runtime.Allocator) -> runtime.Allocator_Error {
	mark := make([]u32, len(cfg.heads), temp) or_return
	members := make([dynamic]Block_Id, temp) or_return
	pending := make([dynamic]Block_Id, temp) or_return
	next_loop: Loop_Index
	for head, block in cfg.heads {
		if fn.nodes.kind[head] != .Loop {
			continue
		}
		header := Block_Id(block)
		source := BLOCK_NONE
		if fn.nodes.input_count[head] == 2 {
			back_input := node_input(fn, head, 1)
			if back_input != NODE_NONE {
				source = cfg.block_of[back_input]
			}
		}

		stamp := u32(next_loop) + 1
		clear(&members)
		clear(&pending)
		mark[header] = stamp
		append(&members, header) or_return
		if source != BLOCK_NONE && mark[source] != stamp {
			mark[source] = stamp
			append(&members, source) or_return
			append(&pending, source) or_return
		}
		for len(pending) > 0 {
			current := pop(&pending)
			for pred in block_preds(cfg^, current) {
				if mark[pred] != stamp {
					mark[pred] = stamp
					append(&members, pred) or_return
					append(&pending, pred) or_return
				}
			}
		}

		parent := cfg.loop_of[header]
		depth: u16 = 1
		if parent != LOOP_NONE {
			depth = cfg.loops[parent].depth + 1
		}
		cfg.loops[next_loop] = Loop_Info {
			header           = header,
			back_edge_source = source,
			parent           = parent,
			depth            = depth,
		}
		for member in members {
			cfg.depths[member] += 1
			cfg.loop_of[member] = next_loop
		}
		next_loop += 1
	}
	return nil
}
