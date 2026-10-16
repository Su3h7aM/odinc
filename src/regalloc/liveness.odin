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

live_out_of_block :: proc(program: ^Program, live_in: []u64, words, block_index: int, out, edge: []u64) {
	for &word in out {
		word = 0
	}
	block := &program.blocks[block_index]
	for successor, successor_index in block.successors {
		copy(edge, bits_row(live_in, words, int(successor)))
		if successor_index < len(block.edge_moves) {
			for move in block.edge_moves[successor_index] {
				bits_remove(edge, int(move.destination))
			}
			for move in block.edge_moves[successor_index] {
				bits_add(edge, int(move.source))
			}
		}
		for word, word_index in edge {
			out[word_index] |= word
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
	words := (vreg_count + BITS_PER_WORD - 1) / BITS_PER_WORD

	intervals, intervals_err := make([]Interval, vreg_count, allocator)
	starts, starts_err := make([]Pos, block_count, allocator)
	storage, storage_err := make([]u64, (3 * block_count + 2) * words, allocator)
	live.intervals = intervals
	live.starts = starts
	defer delete(storage, allocator)
	if intervals_err != nil || starts_err != nil || storage_err != nil {
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

	gen := storage[0:block_count * words]
	kill := storage[block_count * words:2 * block_count * words]
	live_in := storage[2 * block_count * words:3 * block_count * words]
	out := storage[3 * block_count * words:(3 * block_count + 1) * words]
	edge := storage[(3 * block_count + 1) * words:]

	for block_index in 0 ..< block_count {
		block_gen := bits_row(gen, words, block_index)
		block_kill := bits_row(kill, words, block_index)
		instructions := program.blocks[block_index].instructions
		for index := len(instructions) - 1; index >= 0; index -= 1 {
			for operand in instructions[index].operands {
				if operand.role != .Use {
					bits_add(block_kill, int(operand.vreg))
					bits_remove(block_gen, int(operand.vreg))
				}
			}
			for operand in instructions[index].operands {
				if operand.role != .Def {
					bits_add(block_gen, int(operand.vreg))
				}
			}
		}
	}

	for changed := true; changed; {
		changed = false
		for block_index := block_count - 1; block_index >= 0; block_index -= 1 {
			live_out_of_block(program, live_in, words, block_index, out, edge)
			block_in := bits_row(live_in, words, block_index)
			block_gen := bits_row(gen, words, block_index)
			block_kill := bits_row(kill, words, block_index)
			for word_index in 0 ..< words {
				grown := block_gen[word_index] | (out[word_index] &~ block_kill[word_index])
				if grown != block_in[word_index] {
					block_in[word_index] = grown
					changed = true
				}
			}
		}
	}

	if block_count > 0 {
		for word, word_index in bits_row(live_in, words, 0) {
			if word != 0 {
				vreg := word_index * BITS_PER_WORD + int(intrinsics.count_trailing_zeros(word))
				liveness_destroy(live, allocator)
				return Error{kind = .Used_Before_Defined, vreg = Vreg(vreg)}
			}
		}
	}

	for block_index := block_count - 1; block_index >= 0; block_index -= 1 {
		block := &program.blocks[block_index]
		first := starts[block_index]
		last := block_last_pos(program, starts, block_index)
		weight := loop_weight(block.depth)

		live_out_of_block(program, live_in, words, block_index, out, edge)
		for word, word_index in out {
			for bits := word; bits != 0; bits &= bits - 1 {
				vreg := Vreg(word_index * BITS_PER_WORD + int(intrinsics.count_trailing_zeros(bits)))
				add_use(live, vreg, first, last)
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
