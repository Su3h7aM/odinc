// Liveness and live intervals over a `Program`: the facts `linear_scan.odin`
// scans.
//
// The model is Wimmer & Franz, "Linear Scan Register Allocation on SSA Form"
// (2010): one interval per virtual register, made of disjoint position ranges
// (lifetime holes), built by a backward walk over the blocks from the
// per-block live-in sets that a backward dataflow computes.
//
// Positions are two per instruction, early then late, and each block has one
// extra pseudo instruction after its last: its early position reads the
// sources of the block's edge moves and its late position writes their
// destinations.
package regalloc

import "base:intrinsics"
import "base:runtime"
import "core:slice"

Pos :: distinct u32

POSITIONS_PER_INSTRUCTION :: 2
POS_EARLY :: Pos(0)
POS_LATE :: Pos(1)

BITS_PER_WORD :: 64

// A reference inside a loop weighs LOOP_WEIGHT_BASE_SHIFT bits more per level
// of nesting, up to LOOP_DEPTH_CAP levels.
LOOP_WEIGHT_BASE_SHIFT :: 3
LOOP_DEPTH_CAP :: 6

// Pos_Range is one inclusive run of live positions.
Pos_Range :: struct {
	first: Pos,
	last:  Pos,
}

// Interval is the live span of one virtual register. An interval without
// ranges is not live anywhere and gets no location.
Interval :: struct {
	vreg:         Vreg,
	class:        Register_Class,
	// ranges are sorted, disjoint and not adjacent.
	ranges:       [dynamic]Pos_Range,
	// weight sums the loop-weighted references; it is the numerator of the
	// spill cost.
	weight:       u64,
	// clobbered is the set of registers of the vreg's class destroyed by an
	// instruction the vreg is live across.
	clobbered:    Register_Set,
	crosses_call: bool,
}

// Clobber_Point is an instruction that destroys registers.
Clobber_Point :: struct {
	early:    Pos,
	clobbers: [Register_Class]Register_Set,
	is_call:  bool,
	block:    u32,
	index:    u32,
}

// Liveness is the analysis result for one `Program`; `liveness_destroy` frees it.
Liveness :: struct {
	intervals:      []Interval,
	// starts is the first position of every block.
	starts:         []Pos,
	// clobber_points are sorted by position.
	clobber_points: []Clobber_Point,
	out_of_memory:  bool,
}

interval_is_live :: proc "contextless" (interval: ^Interval) -> bool {
	return len(interval.ranges) > 0
}

interval_first :: proc "contextless" (interval: ^Interval) -> Pos {
	return interval.ranges[0].first
}

interval_last :: proc "contextless" (interval: ^Interval) -> Pos {
	return interval.ranges[len(interval.ranges) - 1].last
}

interval_covers :: proc "contextless" (interval: ^Interval, pos: Pos) -> bool {
	low, high := 0, len(interval.ranges)
	for low < high {
		middle := (low + high) / 2
		if interval.ranges[middle].last < pos {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low < len(interval.ranges) && interval.ranges[low].first <= pos
}

block_last_pos :: proc "contextless" (program: ^Program, starts: []Pos, block: int) -> Pos {
	return starts[block] + Pos(POSITIONS_PER_INSTRUCTION * (len(program.blocks[block].instructions) + 1)) - 1
}

loop_weight :: proc "contextless" (depth: u8) -> u64 {
	return u64(1) << (LOOP_WEIGHT_BASE_SHIFT * uint(min(int(depth), LOOP_DEPTH_CAP)))
}

// validate checks the program's references and constraints before any
// analysis indexes with them.
validate :: proc(program: ^Program) -> Error {
	count := len(program.classes)
	for block in program.blocks {
		for successor in block.successors {
			if int(successor) >= len(program.blocks) {
				return Error{kind = .Unknown_Block}
			}
		}
		for moves in block.edge_moves {
			for move in moves {
				if int(move.source) >= count {
					return Error{kind = .Unknown_Vreg, vreg = move.source}
				}
				if int(move.destination) >= count {
					return Error{kind = .Unknown_Vreg, vreg = move.destination}
				}
			}
		}
		for instruction in block.instructions {
			for operand in instruction.operands {
				if int(operand.vreg) >= count {
					return Error{kind = .Unknown_Vreg, vreg = operand.vreg}
				}
			}
			for operand in instruction.operands {
				class := program.classes[operand.vreg]
				switch operand.constraint {
				case .Any:
				case .Fixed:
					if int(operand.fixed) >= REGISTER_LIMIT || int(operand.fixed) not_in program.allocatable[class] {
						return Error{kind = .Unallocatable_Fixed, vreg = operand.vreg}
					}
				case .Reuse_Input:
					valid := operand.role == .Def && int(operand.reuse) < len(instruction.operands)
					if valid {
						input := instruction.operands[operand.reuse]
						valid = input.role == .Use && program.classes[input.vreg] == class
					}
					if !valid {
						return Error{kind = .Reuse_Not_Use, vreg = operand.vreg}
					}
				}
			}
		}
	}
	return Error{}
}

bits_add :: proc "contextless" (bits: []u64, index: int) {
	bits[index / BITS_PER_WORD] |= u64(1) << uint(index % BITS_PER_WORD)
}

bits_remove :: proc "contextless" (bits: []u64, index: int) {
	bits[index / BITS_PER_WORD] &~= u64(1) << uint(index % BITS_PER_WORD)
}

bits_row :: proc "contextless" (storage: []u64, words, row: int) -> []u64 {
	return storage[row * words:(row + 1) * words]
}

// Dataflow solves the live sets over the global vregs: those read before any
// definition in some block, or read by an edge move. Every other vreg is local
// to its block and never enters a live set, so it needs no bit.
Dataflow :: struct {
	program:           ^Program,
	words:             int,
	// global_index is the bit of each vreg, -1 for a block-local vreg.
	global_index:      []i32,
	// global_vregs is the vreg of each bit, in ascending vreg order.
	global_vregs:      []Vreg,
	// gen, kill and live_in hold one row of `words` bits per block; out and
	// edge are scratch rows for the live-out set of one block.
	gen:               []u64,
	kill:              []u64,
	live_in:           []u64,
	out:               []u64,
	edge:              []u64,
	// predecessors of block b are predecessor_list[predecessor_start[b]:predecessor_start[b + 1]].
	predecessor_start: []u32,
	predecessor_list:  []u32,
	// queue holds the blocks whose live-in may be stale; queued marks them.
	queue:             []u32,
	queued:            []bool,
}

dataflow_make :: proc(program: ^Program, allocator: runtime.Allocator) -> (flow: Dataflow, err: runtime.Allocator_Error) {
	vreg_count := len(program.classes)
	block_count := len(program.blocks)
	flow.program = program

	is_global := make([]bool, vreg_count, allocator) or_return
	defined_in := make([]u32, vreg_count, allocator) or_return
	for block, block_index in program.blocks {
		marker := u32(block_index + 1)
		for instruction in block.instructions {
			for operand in instruction.operands {
				if operand.role != .Def && defined_in[operand.vreg] != marker {
					is_global[operand.vreg] = true
				}
			}
			for operand in instruction.operands {
				if operand.role != .Use {
					defined_in[operand.vreg] = marker
				}
			}
		}
		for moves in block.edge_moves {
			for move in moves {
				is_global[move.source] = true
			}
		}
	}

	flow.global_index = make([]i32, vreg_count, allocator) or_return
	flow.global_vregs = make([]Vreg, vreg_count, allocator) or_return
	global_count := 0
	for is_global_vreg, vreg in is_global {
		if is_global_vreg {
			flow.global_index[vreg] = i32(global_count)
			flow.global_vregs[global_count] = Vreg(vreg)
			global_count += 1
		} else {
			flow.global_index[vreg] = -1
		}
	}
	flow.global_vregs = flow.global_vregs[:global_count]
	words := (global_count + BITS_PER_WORD - 1) / BITS_PER_WORD
	flow.words = words

	storage := make([]u64, (3 * block_count + 2) * words, allocator) or_return
	flow.gen = storage[0:block_count * words]
	flow.kill = storage[block_count * words:2 * block_count * words]
	flow.live_in = storage[2 * block_count * words:3 * block_count * words]
	flow.out = storage[3 * block_count * words:(3 * block_count + 1) * words]
	flow.edge = storage[(3 * block_count + 1) * words:]

	for block, block_index in program.blocks {
		block_gen := bits_row(flow.gen, words, block_index)
		block_kill := bits_row(flow.kill, words, block_index)
		for index := len(block.instructions) - 1; index >= 0; index -= 1 {
			for operand in block.instructions[index].operands {
				if operand.role != .Use {
					bits_add_vreg(flow.global_index, block_kill, operand.vreg)
					bits_remove_vreg(flow.global_index, block_gen, operand.vreg)
				}
			}
			for operand in block.instructions[index].operands {
				if operand.role != .Def {
					bits_add_vreg(flow.global_index, block_gen, operand.vreg)
				}
			}
		}
	}

	flow.predecessor_start = make([]u32, block_count + 1, allocator) or_return
	for block in program.blocks {
		for successor in block.successors {
			flow.predecessor_start[successor + 1] += 1
		}
	}
	for block_index in 0 ..< block_count {
		flow.predecessor_start[block_index + 1] += flow.predecessor_start[block_index]
	}
	flow.predecessor_list = make([]u32, flow.predecessor_start[block_count], allocator) or_return
	fill := make([]u32, block_count, allocator) or_return
	copy(fill, flow.predecessor_start[:block_count])
	for block, block_index in program.blocks {
		for successor in block.successors {
			flow.predecessor_list[fill[successor]] = u32(block_index)
			fill[successor] += 1
		}
	}

	flow.queue = make([]u32, block_count, allocator) or_return
	flow.queued = make([]bool, block_count, allocator) or_return
	return
}

bits_add_vreg :: proc "contextless" (global_index: []i32, bits: []u64, vreg: Vreg) {
	if index := global_index[vreg]; index >= 0 {
		bits_add(bits, int(index))
	}
}

bits_remove_vreg :: proc "contextless" (global_index: []i32, bits: []u64, vreg: Vreg) {
	if index := global_index[vreg]; index >= 0 {
		bits_remove(bits, int(index))
	}
}

// live_out_of_block fills flow.out with the union over the successors of the
// successor's live-in, minus the edge's destinations, plus its sources when
// `with_sources`; the intervals leave them out because the edge copy reads a
// source before the destination is written, so the two may share a register.
live_out_of_block :: proc(flow: ^Dataflow, block_index: int, with_sources: bool) {
	for &word in flow.out {
		word = 0
	}
	block := &flow.program.blocks[block_index]
	for successor, successor_index in block.successors {
		successor_in := bits_row(flow.live_in, flow.words, int(successor))
		moves: []Move
		if successor_index < len(block.edge_moves) {
			moves = block.edge_moves[successor_index]
		}
		if len(moves) == 0 {
			for word, word_index in successor_in {
				flow.out[word_index] |= word
			}
			continue
		}
		copy(flow.edge, successor_in)
		for move in moves {
			bits_remove_vreg(flow.global_index, flow.edge, move.destination)
		}
		if with_sources {
			for move in moves {
				bits_add_vreg(flow.global_index, flow.edge, move.source)
			}
		}
		for word, word_index in flow.edge {
			flow.out[word_index] |= word
		}
	}
}

// update_live_in recomputes one block's live-in and reports whether it grew.
update_live_in :: proc(flow: ^Dataflow, block: int) -> (changed: bool) {
	gen := bits_row(flow.gen, flow.words, block)
	kill := bits_row(flow.kill, flow.words, block)
	live_in := bits_row(flow.live_in, flow.words, block)
	for word_index in 0 ..< flow.words {
		grown := gen[word_index] | (flow.out[word_index] &~ kill[word_index])
		if grown != live_in[word_index] {
			live_in[word_index] = grown
			changed = true
		}
	}
	return
}

// solve_live_in runs the backward dataflow to its fixed point. Blocks are
// seeded so that the last block is taken first, which is the postorder of a
// function laid out entry first; a block re-enters the queue only when one of
// its successors changed its live-in.
solve_live_in :: proc(flow: ^Dataflow) {
	block_count := len(flow.program.blocks)
	top := block_count
	for block in 0 ..< block_count {
		flow.queue[block] = u32(block)
		flow.queued[block] = true
	}
	for top > 0 {
		top -= 1
		block := int(flow.queue[top])
		flow.queued[block] = false
		live_out_of_block(flow, block, true)
		if !update_live_in(flow, block) {
			continue
		}
		predecessors := flow.predecessor_list[flow.predecessor_start[block]:flow.predecessor_start[block + 1]]
		for predecessor in predecessors {
			if !flow.queued[predecessor] {
				flow.queued[predecessor] = true
				flow.queue[top] = predecessor
				top += 1
			}
		}
	}
}

// liveness computes the live intervals of every vreg of `program`. A vreg
// live at the entry of block 0 is an error: nothing defines it.
liveness :: proc(live: ^Liveness, program: ^Program, allocator := context.allocator) -> Error {
	if err := validate(program); err.kind != .None {
		return err
	}
	context.allocator = allocator
	vreg_count := len(program.classes)
	block_count := len(program.blocks)

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	scratch_allocator := context.temp_allocator

	intervals, intervals_err := make([]Interval, vreg_count, allocator)
	starts, starts_err := make([]Pos, block_count, allocator)
	live.intervals = intervals
	live.starts = starts
	flow, flow_err := dataflow_make(program, scratch_allocator)
	if intervals_err != nil || starts_err != nil || flow_err != nil {
		liveness_destroy(live, allocator)
		return Error{kind = .Out_Of_Memory}
	}

	for vreg in 0 ..< vreg_count {
		intervals[vreg] = Interval {
			vreg  = Vreg(vreg),
			class = program.classes[vreg],
		}
	}
	position := Pos(0)
	for block, block_index in program.blocks {
		starts[block_index] = position
		position += Pos(POSITIONS_PER_INSTRUCTION * (len(block.instructions) + 1))
	}

	solve_live_in(&flow)

	if block_count > 0 {
		for word, word_index in bits_row(flow.live_in, flow.words, 0) {
			if word != 0 {
				index := word_index * BITS_PER_WORD + int(intrinsics.count_trailing_zeros(word))
				liveness_destroy(live, allocator)
				return Error{kind = .Used_Before_Defined, vreg = flow.global_vregs[index]}
			}
		}
	}

	for block_index := block_count - 1; block_index >= 0; block_index -= 1 {
		block := &program.blocks[block_index]
		first := starts[block_index]
		last := block_last_pos(program, starts, block_index)
		weight := loop_weight(block.depth)

		live_out_of_block(&flow, block_index, false)
		for word, word_index in flow.out {
			for bits := word; bits != 0; bits &= bits - 1 {
				global := word_index * BITS_PER_WORD + int(intrinsics.count_trailing_zeros(bits))
				add_use(live, flow.global_vregs[global], first, last)
			}
		}

		for moves in block.edge_moves {
			for move in moves {
				add_def(live, move.destination, last)
				intervals[move.destination].weight += weight
			}
		}
		for moves in block.edge_moves {
			for move in moves {
				add_use(live, move.source, first, last - 1)
				intervals[move.source].weight += weight
			}
		}

		for index := len(block.instructions) - 1; index >= 0; index -= 1 {
			instruction := &block.instructions[index]
			early := first + Pos(POSITIONS_PER_INSTRUCTION * index)
			for operand in instruction.operands {
				intervals[operand.vreg].weight += weight
				switch operand.role {
				case .Def:
					add_def(live, operand.vreg, operand_pos(operand, early))
				case .Use_Def:
					add_def(live, operand.vreg, early + POS_LATE)
				case .Use:
				}
			}
			for operand in instruction.operands {
				switch operand.role {
				case .Use:
					add_use(live, operand.vreg, first, operand_pos(operand, early))
				case .Use_Def:
					add_use(live, operand.vreg, first, early)
				case .Def:
				}
			}
		}
	}

	for &interval in intervals {
		slice.reverse(interval.ranges[:])
		merged := 0
		for range in interval.ranges {
			if merged > 0 && range.first <= interval.ranges[merged - 1].last + 1 {
				interval.ranges[merged - 1].last = max(interval.ranges[merged - 1].last, range.last)
			} else {
				interval.ranges[merged] = range
				merged += 1
			}
		}
		resize(&interval.ranges, merged)
	}

	points := make([dynamic]Clobber_Point, allocator)
	for block, block_index in program.blocks {
		for instruction, index in block.instructions {
			if instruction.clobbers != {} || instruction.is_call {
				_, append_err := append(
					&points,
					Clobber_Point {
						early = starts[block_index] + Pos(POSITIONS_PER_INSTRUCTION * index),
						clobbers = instruction.clobbers,
						is_call = instruction.is_call,
						block = u32(block_index),
						index = u32(index),
					},
				)
				if append_err != nil {
					live.out_of_memory = true
				}
			}
		}
	}
	live.clobber_points = points[:]

	for &interval in intervals {
		for range in interval.ranges {
			low, high := 0, len(points)
			for low < high {
				middle := (low + high) / 2
				if points[middle].early < range.first {
					low = middle + 1
				} else {
					high = middle
				}
			}
			for point_index := low; point_index < len(points) && points[point_index].early + POS_LATE <= range.last; point_index += 1 {
				point := &points[point_index]
				if instruction_defines(&program.blocks[point.block].instructions[point.index], interval.vreg) {
					continue
				}
				interval.clobbered += point.clobbers[interval.class]
				interval.crosses_call ||= point.is_call
			}
		}
	}

	if live.out_of_memory {
		liveness_destroy(live, allocator)
		return Error{kind = .Out_Of_Memory}
	}
	return Error{}
}

operand_pos :: proc "contextless" (operand: Operand, early: Pos) -> Pos {
	return early if operand.position == .Early else early + POS_LATE
}

instruction_defines :: proc "contextless" (instruction: ^Instruction, vreg: Vreg) -> bool {
	for operand in instruction.operands {
		if operand.vreg == vreg && operand.role != .Use {
			return true
		}
	}
	return false
}

// add_use and add_def build ranges while the walk descends through
// positions, so the tail range is always the one closest after `pos`.
add_use :: proc(live: ^Liveness, vreg: Vreg, block_first, pos: Pos) {
	interval := &live.intervals[vreg]
	if count := len(interval.ranges); count > 0 {
		tail := &interval.ranges[count - 1]
		if pos + 1 >= tail.first {
			tail.first = min(tail.first, block_first)
			tail.last = max(tail.last, pos)
			return
		}
	}
	if _, err := append(&interval.ranges, Pos_Range{first = block_first, last = pos}); err != nil {
		live.out_of_memory = true
	}
}

add_def :: proc(live: ^Liveness, vreg: Vreg, pos: Pos) {
	interval := &live.intervals[vreg]
	if count := len(interval.ranges); count > 0 {
		tail := &interval.ranges[count - 1]
		if tail.first <= pos && pos <= tail.last {
			tail.first = pos
			return
		}
	}
	if _, err := append(&interval.ranges, Pos_Range{first = pos, last = pos}); err != nil {
		live.out_of_memory = true
	}
}

// liveness_destroy frees everything the analysis allocated. Safe on a zero
// or already destroyed Liveness.
liveness_destroy :: proc(live: ^Liveness, allocator := context.allocator) {
	for &interval in live.intervals {
		delete(interval.ranges)
	}
	delete(live.intervals, allocator)
	delete(live.starts, allocator)
	delete(live.clobber_points, allocator)
	live^ = {}
}
