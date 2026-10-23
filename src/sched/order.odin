package sched

import "base:runtime"
import "core:container/priority_queue"
import "core:slice"
import ir "oc:ir"

Block :: struct {
	id:    ir.Block_Id,
	head:  ir.Node_Id,
	nodes: []ir.Node_Id,
	depth: u16,
	cold:  bool,
}

// `blocks` is in layout order: the entry first, `cold` blocks last. `placement` is indexed by node id and
// holds `ir.BLOCK_NONE` for nodes outside any block (heads, rematerialized values, dead or unreachable code).
Schedule :: struct {
	cfg:       ir.Cfg,
	blocks:    []Block,
	placement: []ir.Block_Id,
	ordered:   []ir.Node_Id,
}

schedule_destroy :: proc(schedule: ^Schedule, allocator: runtime.Allocator) {
	ir.cfg_destroy(&schedule.cfg, allocator)
	delete(schedule.blocks, allocator)
	delete(schedule.placement, allocator)
	delete(schedule.ordered, allocator)
	schedule^ = {}
}

// Stage A of section 12: pinned nodes and phis stay in their block, pure values go to the common
// dominator of their uses, and each block is ordered by the rules of section 7 with ties broken by id.
order :: proc(fn: ^ir.Function, allocator: runtime.Allocator) -> (schedule: Schedule, err: runtime.Allocator_Error) {
	defer if err != nil {
		schedule_destroy(&schedule, allocator)
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temp := context.temp_allocator

	node_count := len(fn.nodes)
	schedule.placement = make([]ir.Block_Id, node_count, allocator) or_return
	slice.fill(schedule.placement, ir.BLOCK_NONE)
	uses := ir.uses_build(fn, temp) or_return
	schedule.cfg = ir.build_control_skeleton(fn, allocator, uses, temp) or_return
	if len(schedule.cfg.heads) == 0 {
		return
	}
	block_count := len(schedule.cfg.heads)
	place_floating(fn, schedule.cfg, uses, schedule.placement, temp) or_return

	for index in 1 ..< node_count {
		id := ir.Node_Id(index)
		kind := fn.nodes.kind[id]
		if !is_floating(fn, id) && (kind == .Phi || ir.is_pinned(kind)) {
			schedule.placement[id] = ir.block_of_node(schedule.cfg, fn, id)
		}
	}

	first := make([]u32, block_count + 1, temp) or_return
	member_count := 0
	for block in schedule.placement {
		if block != ir.BLOCK_NONE {
			first[int(block) + 1] += 1
			member_count += 1
		}
	}
	for block in 0 ..< block_count {
		first[block + 1] += first[block]
	}
	members := make([]ir.Node_Id, member_count, temp) or_return
	cursor := make([]u32, block_count, temp) or_return
	copy(cursor, first[:block_count])
	for block, index in schedule.placement {
		if block != ir.BLOCK_NONE {
			members[cursor[block]] = ir.Node_Id(index)
			cursor[block] += 1
		}
	}

	ordering := Ordering {
		fn          = fn,
		cfg         = schedule.cfg,
		placement   = schedule.placement,
		taker       = make([]ir.Node_Id, node_count, temp) or_return,
		local_index = make([]u32, node_count, temp) or_return,
		temp        = temp,
	}
	index_state_takers(&ordering)

	schedule.ordered = make([]ir.Node_Id, member_count, allocator) or_return
	for block in 0 ..< block_count {
		order_block(&ordering, ir.Block_Id(block), members[first[block]:first[block + 1]], schedule.ordered[first[block]:first[block + 1]]) or_return
	}

	schedule.blocks = make([]Block, block_count, allocator) or_return
	position := 0
	for want_cold in ([2]bool{false, true}) {
		for head, block in schedule.cfg.heads {
			cold := .Cold in fn.nodes.flags[head]
			if cold != want_cold {
				continue
			}
			schedule.blocks[position] = Block {
				id    = ir.Block_Id(block),
				head  = head,
				nodes = schedule.ordered[first[block]:first[block + 1]],
				depth = schedule.cfg.depths[block],
				cold  = cold,
			}
			position += 1
		}
	}
	return schedule, nil
}

// Pure values and non-control projections, unless the kind is rematerialized.
@(private = "file")
is_floating :: proc(fn: ^ir.Function, id: ir.Node_Id) -> bool {
	kind := fn.nodes.kind[id]
	if .Rematerialize in ir.kind_info[kind].flags {
		return false
	}
	return ir.is_pure(kind) || (kind == .Proj && fn.nodes.type[id] != .Control)
}

// Kahn's algorithm over the floating users: a value is placed after all its users are placed.
@(private = "file")
place_floating :: proc(fn: ^ir.Function, cfg: ir.Cfg, uses: ir.Use_Table, placement: []ir.Block_Id, temp: runtime.Allocator) -> runtime.Allocator_Error {
	pending := make([]u32, len(fn.nodes), temp) or_return
	ready := make([dynamic]ir.Node_Id, temp) or_return
	floating_count := 0
	for index in 1 ..< len(fn.nodes) {
		id := ir.Node_Id(index)
		if !is_floating(fn, id) {
			continue
		}
		floating_count += 1
		for use in ir.uses_of(uses, id) {
			if is_floating(fn, use.user) {
				pending[id] += 1
			}
		}
		if pending[id] == 0 {
			append(&ready, id) or_return
		}
	}

	placed := 0
	for len(ready) > 0 {
		id := pop(&ready)
		placement[id] = use_common_block(fn, cfg, placement, uses, id)
		placed += 1
		for input in ir.node_inputs(fn, id) {
			if input == ir.NODE_NONE || !is_floating(fn, input) {
				continue
			}
			pending[input] -= 1
			if pending[input] == 0 {
				append(&ready, input) or_return
			}
		}
	}
	assert(placed == floating_count, "floating values form a cycle")
	return nil
}

@(private = "file")
use_common_block :: proc(fn: ^ir.Function, cfg: ir.Cfg, placement: []ir.Block_Id, uses: ir.Use_Table, id: ir.Node_Id) -> ir.Block_Id {
	common := ir.BLOCK_NONE
	for use in ir.uses_of(uses, id) {
		block := read_block(fn, cfg, placement, use)
		if block == ir.BLOCK_NONE {
			continue
		}
		common = block if common == ir.BLOCK_NONE else common_dominator(cfg, common, block)
	}
	return common
}

// The block whose end reads the operand: a phi reads its value at the end of the predecessor
// whose input matches (region input `slot - 1`).
@(private = "file")
read_block :: proc(fn: ^ir.Function, cfg: ir.Cfg, placement: []ir.Block_Id, use: ir.Use) -> ir.Block_Id {
	if fn.nodes.kind[use.user] == .Phi {
		slot := int(use.slot)
		region := ir.node_input(fn, use.user, 0)
		if slot == 0 || slot > int(fn.nodes.input_count[region]) {
			return ir.BLOCK_NONE
		}
		return cfg.block_of[ir.node_input(fn, region, slot - 1)]
	}
	if is_floating(fn, use.user) {
		return placement[use.user]
	}
	return ir.block_of_node(cfg, fn, use.user)
}

// Blocks are numbered in reverse post-order, so a dominator has a smaller number than its dominated blocks.
@(private = "file")
common_dominator :: proc(cfg: ir.Cfg, a, b: ir.Block_Id) -> ir.Block_Id {
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

@(private = "file")
Ordering :: struct {
	fn:          ^ir.Function,
	cfg:         ir.Cfg,
	placement:   []ir.Block_Id,
	// The one node that takes over each memory state, by state id.
	taker:       []ir.Node_Id,
	local_index: []u32,
	temp:        runtime.Allocator,
}

@(private = "file")
index_state_takers :: proc(ordering: ^Ordering) {
	fn := ordering.fn
	for index in 1 ..< len(fn.nodes) {
		consumer := ir.Node_Id(index)
		kind := fn.nodes.kind[consumer]
		if kind == .Phi || kind == .Load || fn.nodes.input_count[consumer] < 2 {
			continue
		}
		state := ir.node_input(fn, consumer, 1)
		if fn.nodes.type[state] == .Memory {
			ordering.taker[state] = consumer
		}
	}
}

// Phis first, then the rest by Kahn's algorithm: data edges inside the block, a plain `Load` before
// the node taking over its state (rule 3), and the exit last. Ties are broken by the smaller id (rule 4).
@(private = "file")
order_block :: proc(ordering: ^Ordering, block: ir.Block_Id, members: []ir.Node_Id, out: []ir.Node_Id) -> runtime.Allocator_Error {
	fn := ordering.fn
	phi_count := 0
	rest := make([dynamic]ir.Node_Id, ordering.temp) or_return
	for member in members {
		if fn.nodes.kind[member] == .Phi {
			out[phi_count] = member
			phi_count += 1
		} else {
			append(&rest, member) or_return
		}
	}
	count := len(rest)
	for member, index in rest {
		ordering.local_index[member] = u32(index)
	}

	edges := make([dynamic][2]u32, ordering.temp) or_return
	exit := ordering.cfg.exits[block]
	for member in rest {
		for input in ir.node_inputs(fn, member) {
			if input != ir.NODE_NONE && fn.nodes.kind[input] != .Phi && ordering.placement[input] == block {
				append(&edges, [2]u32{ordering.local_index[input], ordering.local_index[member]}) or_return
			}
		}
		if fn.nodes.kind[member] == .Load {
			taker := ordering.taker[ir.node_input(fn, member, 1)]
			if taker != ir.NODE_NONE && taker != member && ordering.placement[taker] == block {
				append(&edges, [2]u32{ordering.local_index[member], ordering.local_index[taker]}) or_return
			}
		}
		if exit != ir.NODE_NONE && member != exit {
			append(&edges, [2]u32{ordering.local_index[member], ordering.local_index[exit]}) or_return
		}
	}

	successor_first := make([]u32, count + 1, ordering.temp) or_return
	indegree := make([]u32, count, ordering.temp) or_return
	for edge in edges {
		successor_first[edge[0] + 1] += 1
		indegree[edge[1]] += 1
	}
	for index in 0 ..< count {
		successor_first[index + 1] += successor_first[index]
	}
	successors := make([]u32, len(edges), ordering.temp) or_return
	cursor := make([]u32, count, ordering.temp) or_return
	copy(cursor, successor_first[:count])
	for edge in edges {
		successors[cursor[edge[0]]] = edge[1]
		cursor[edge[0]] += 1
	}

	ready: priority_queue.Priority_Queue(ir.Node_Id)
	priority_queue.init(&ready, node_id_less, priority_queue.default_swap_proc(ir.Node_Id), count, ordering.temp) or_return
	for index in 0 ..< count {
		if indegree[index] == 0 {
			priority_queue.push(&ready, rest[index]) or_return
		}
	}
	emitted := phi_count
	for priority_queue.len(ready) > 0 {
		member := priority_queue.pop(&ready)
		out[emitted] = member
		emitted += 1
		local := ordering.local_index[member]
		for successor in successors[successor_first[local]:successor_first[local + 1]] {
			indegree[successor] -= 1
			if indegree[successor] == 0 {
				priority_queue.push(&ready, rest[successor]) or_return
			}
		}
	}
	assert(emitted == len(out), "block has a dependence cycle")
	return nil
}

@(private = "file")
node_id_less :: proc(a, b: ir.Node_Id) -> bool {
	return a < b
}
