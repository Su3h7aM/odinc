// Linear scan over whole-life intervals.
//
// Poletto & Sarkar (1999) scan the intervals in order of start and give each
// a register or a spill; Wimmer & Franz (2010) make the intervals hole-aware
// and allocate fixed (pre-coloured) ones first. This scan keeps, per register,
// a sorted table of the position ranges that are taken, so a vreg fits a
// register exactly when none of its ranges overlaps the table. When nothing
// fits, the cheapest set of vregs to spill (the candidate itself or the
// holders of one register) is spilled for its whole life; spill cost is
// loop-weighted references divided by interval length (docs/research/06,
// section 2.4). No interval is split, so a spilled vreg stays in its slot and
// the emitter reaches it through scratch registers.
//
// Register choice: a coalescing hint (move partner, reuse-input source) first,
// then callee-saved registers for an interval that crosses a call and
// caller-saved ones otherwise. A register that an instruction the interval is
// live across destroys is never offered.
//
// Reuse-input: the def shares the register of its input when it can. When it
// cannot, `allocate` inserts `def <- input` before the instruction and keeps
// the def's register free at the instruction's early position.
package regalloc

import "core:slice"

COST_SCALE :: 1024
COST_INFINITE :: max(u64)
NO_HINT :: max(u32)
NO_EDGE :: -1

Occupied :: struct {
	first: Pos,
	last:  Pos,
	owner: Vreg,
}

Reuse_Edge :: struct {
	def:   Vreg,
	input: Vreg,
	early: Pos,
	block: u32,
	index: u32,
	next:  int,
}

Fixed_Requirement :: struct {
	has:      bool,
	register: Register,
}

Scan :: struct {
	program:      ^Program,
	live:         ^Liveness,
	location:     []Location,
	occupancy:    [Register_Class][REGISTER_LIMIT][dynamic]Occupied,
	edges:        [dynamic]Reuse_Edge,
	edge_head:    []int,
	hint:         []u32,
	fixed:        []Fixed_Requirement,
	reuse_locked: []bool,
	slot_count:   u32,
}

// allocate gives every live vreg of `program` a register or a spill slot.
// The program must outlive the result's use of it only for `verify`.
allocate :: proc(program: ^Program, allocator := context.allocator) -> (result: Result, err: Error) {
	live: Liveness
	err = liveness(&live, program, allocator)
	if err.kind != .None {
		return
	}
	defer liveness_destroy(&live, allocator)
	context.allocator = allocator

	vreg_count := len(program.classes)
	scan := Scan {
		program = program,
		live    = &live,
	}
	scan.location, _ = make([]Location, vreg_count, allocator)
	scan.edge_head, _ = make([]int, vreg_count, allocator)
	scan.hint, _ = make([]u32, vreg_count, allocator)
	scan.fixed, _ = make([]Fixed_Requirement, vreg_count, allocator)
	scan.reuse_locked, _ = make([]bool, vreg_count, allocator)
	defer scan_destroy(&scan, allocator)
	if vreg_count > 0 && (scan.location == nil || scan.edge_head == nil || scan.hint == nil || scan.fixed == nil || scan.reuse_locked == nil) {
		delete(scan.location, allocator)
		return {}, Error{kind = .Out_Of_Memory}
	}
	for vreg in 0 ..< vreg_count {
		scan.edge_head[vreg] = NO_EDGE
		scan.hint[vreg] = NO_HINT
	}

	if err = scan_prepare(&scan); err.kind != .None {
		delete(scan.location, allocator)
		return {}, err
	}

	order := make([dynamic]Vreg, allocator)
	defer delete(order)
	for &interval in live.intervals {
		if interval_is_live(&interval) {
			append(&order, interval.vreg)
		}
	}
	slice.sort_by_with_data(order[:], proc(a, b: Vreg, data: rawptr) -> bool {
			intervals := (^[]Interval)(data)^
			first_a, first_b := interval_first(&intervals[a]), interval_first(&intervals[b])
			return first_a < first_b || (first_a == first_b && a < b)
		}, &live.intervals)

	for fixed_pass in ([2]bool{true, false}) {
		for vreg in order {
			if scan.fixed[vreg].has != fixed_pass {
				continue
			}
			if err = assign(&scan, vreg); err.kind != .None {
				delete(scan.location, allocator)
				return {}, err
			}
		}
	}

	for vreg in order {
		if register, is_register := scan.location[vreg].(Register); is_register {
			class := live.intervals[vreg].class
			if int(register) in program.callee_saved[class] {
				result.callee_saved_used[class] += {int(register)}
			}
		}
	}
	moves := reuse_moves(scan.edges[:], scan.location, allocator)
	result.inserted_moves = moves[:]
	result.location = scan.location
	result.spill_slot_count = scan.slot_count
	return
}

scan_destroy :: proc(scan: ^Scan, allocator := context.allocator) {
	for &class_table in scan.occupancy {
		for &table in class_table {
			delete(table)
		}
	}
	delete(scan.edges)
	delete(scan.edge_head, allocator)
	delete(scan.hint, allocator)
	delete(scan.fixed, allocator)
	delete(scan.reuse_locked, allocator)
}

// scan_prepare collects fixed requirements, coalescing hints and reuse edges.
scan_prepare :: proc(scan: ^Scan) -> Error {
	program := scan.program
	set_hint :: proc(scan: ^Scan, a, b: Vreg) {
		if scan.program.classes[a] != scan.program.classes[b] {
			return
		}
		if scan.hint[a] == NO_HINT {
			scan.hint[a] = u32(b)
		}
		if scan.hint[b] == NO_HINT {
			scan.hint[b] = u32(a)
		}
	}

	for block, block_index in program.blocks {
		for moves in block.edge_moves {
			for move in moves {
				set_hint(scan, move.source, move.destination)
			}
		}
		for instruction, index in block.instructions {
			for operand in instruction.operands {
				switch operand.constraint {
				case .Any:
				case .Fixed:
					requirement := &scan.fixed[operand.vreg]
					if requirement.has && requirement.register != operand.fixed {
						return Error{kind = .Conflicting_Fixed, vreg = operand.vreg}
					}
					requirement^ = Fixed_Requirement {
						has      = true,
						register = operand.fixed,
					}
				case .Reuse_Input:
					input := instruction.operands[operand.reuse].vreg
					if input == operand.vreg {
						continue
					}
					edge := Reuse_Edge {
						def   = operand.vreg,
						input = input,
						early = scan.live.starts[block_index] + Pos(POSITIONS_PER_INSTRUCTION * index),
						block = u32(block_index),
						index = u32(index),
						next  = scan.edge_head[operand.vreg],
					}
					scan.edge_head[operand.vreg] = len(scan.edges)
					append(&scan.edges, edge)
					set_hint(scan, operand.vreg, input)
				}
			}
			if instruction.is_move && len(instruction.operands) == 2 {
				set_hint(scan, instruction.operands[0].vreg, instruction.operands[1].vreg)
			}
		}
	}
	return Error{}
}

// reuse_moves lists the copies the reuse-input pairs need under `location`,
// in the order of `edges`, which is program order.
reuse_moves :: proc(edges: []Reuse_Edge, location: []Location, allocator := context.allocator) -> [dynamic]Move_At {
	moves := make([dynamic]Move_At, allocator)
	for edge in edges {
		if location[edge.def] != location[edge.input] {
			append(&moves, Move_At{block = edge.block, before = edge.index, move = Move{source = edge.input, destination = edge.def}})
		}
	}
	return moves
}

spill_cost :: proc(scan: ^Scan, vreg: Vreg) -> u64 {
	if scan.fixed[vreg].has {
		return COST_INFINITE
	}
	interval := &scan.live.intervals[vreg]
	length := u64(interval_last(interval) - interval_first(interval)) + 1
	return min(interval.weight * COST_SCALE / length, COST_INFINITE - 1)
}

blocking_cost :: proc(scan: ^Scan, vreg: Vreg) -> u64 {
	if scan.reuse_locked[vreg] {
		return COST_INFINITE
	}
	return spill_cost(scan, vreg)
}

assign :: proc(scan: ^Scan, vreg: Vreg) -> Error {
	interval := &scan.live.intervals[vreg]
	allowed := scan.program.allocatable[interval.class] - interval.clobbered
	if requirement := scan.fixed[vreg]; requirement.has {
		allowed &= Register_Set{int(requirement.register)}
	}
	preferred: [REGISTER_LIMIT]Register
	count := preference_order(scan, vreg, allowed, &preferred)

	for index in 0 ..< count {
		if !has_conflict(scan, vreg, preferred[index], nil) {
			place(scan, vreg, preferred[index])
			return Error{}
		}
	}

	owners := make([dynamic]Vreg, context.temp_allocator)
	cheapest_owners := make([dynamic]Vreg, context.temp_allocator)
	cheapest_cost := COST_INFINITE
	cheapest_register := -1
	for index in 0 ..< count {
		clear(&owners)
		has_conflict(scan, vreg, preferred[index], &owners)
		cost: u64
		for owner in owners {
			blocking := blocking_cost(scan, owner)
			cost = COST_INFINITE if blocking == COST_INFINITE || cost + blocking < cost else cost + blocking
			if cost == COST_INFINITE {
				break
			}
		}
		if cost < cheapest_cost {
			cheapest_cost = cost
			cheapest_register = int(preferred[index])
			clear(&cheapest_owners)
			append(&cheapest_owners, ..owners[:])
		}
	}

	candidate_cost := spill_cost(scan, vreg)
	if candidate_cost != COST_INFINITE && candidate_cost <= cheapest_cost {
		spill(scan, vreg)
		return Error{}
	}
	if cheapest_register < 0 {
		return Error{kind = .No_Register_Available, vreg = vreg}
	}
	for owner in cheapest_owners {
		unplace(scan, owner)
		spill(scan, owner)
	}
	place(scan, vreg, Register(cheapest_register))
	return Error{}
}

// preference_order lists the allowed registers best first.
preference_order :: proc(scan: ^Scan, vreg: Vreg, allowed: Register_Set, order: ^[REGISTER_LIMIT]Register) -> int {
	interval := &scan.live.intervals[vreg]
	count := 0
	seen: Register_Set
	offer :: proc(register: int, allowed: Register_Set, seen: ^Register_Set, order: ^[REGISTER_LIMIT]Register, count: ^int) {
		if register in allowed && register not_in seen^ {
			order[count^] = Register(register)
			count^ += 1
			seen^ += {register}
		}
	}

	if partner := scan.hint[vreg]; partner != NO_HINT {
		if register, ok := scan.location[partner].(Register); ok {
			offer(int(register), allowed, &seen, order, &count)
		}
	}
	for edge_index := scan.edge_head[vreg]; edge_index != NO_EDGE; edge_index = scan.edges[edge_index].next {
		if register, ok := scan.location[scan.edges[edge_index].input].(Register); ok {
			offer(int(register), allowed, &seen, order, &count)
		}
	}
	callee := allowed & scan.program.callee_saved[interval.class]
	caller := allowed - callee
	first, second := caller, callee
	if interval.crosses_call {
		first, second = callee, caller
	}
	for register in first {
		offer(register, allowed, &seen, order, &count)
	}
	for register in second {
		offer(register, allowed, &seen, order, &count)
	}
	return count
}

// needs_extra says whether placing the def of `edge` in `register` must also
// reserve the early position for the copy of the input.
needs_extra :: proc(scan: ^Scan, edge: ^Reuse_Edge, register: Register) -> bool {
	if input_register, ok := scan.location[edge.input].(Register); ok && input_register == register {
		return false
	}
	return !interval_covers(&scan.live.intervals[edge.def], edge.early)
}

// has_conflict reports whether `vreg` overlaps something already in
// `register`; with `owners` it also collects every distinct overlapped vreg.
has_conflict :: proc(scan: ^Scan, vreg: Vreg, register: Register, owners: ^[dynamic]Vreg) -> bool {
	interval := &scan.live.intervals[vreg]
	occupied := scan.occupancy[interval.class][register][:]
	found := false
	check :: proc(occupied: []Occupied, first, last: Pos, vreg: Vreg, owners: ^[dynamic]Vreg) -> bool {
		found := false
		for index := first_ending_at_or_after(occupied, first); index < len(occupied) && occupied[index].first <= last; index += 1 {
			owner := occupied[index].owner
			if owner == vreg {
				continue
			}
			if owners == nil {
				return true
			}
			found = true
			if !slice.contains(owners[:], owner) {
				append(owners, owner)
			}
		}
		return found
	}
	for range in interval.ranges {
		if check(occupied, range.first, range.last, vreg, owners) {
			if owners == nil {
				return true
			}
			found = true
		}
	}
	for edge_index := scan.edge_head[vreg]; edge_index != NO_EDGE; edge_index = scan.edges[edge_index].next {
		edge := &scan.edges[edge_index]
		if needs_extra(scan, edge, register) && check(occupied, edge.early, edge.early, vreg, owners) {
			if owners == nil {
				return true
			}
			found = true
		}
	}
	return found
}

first_ending_at_or_after :: proc "contextless" (occupied: []Occupied, pos: Pos) -> int {
	low, high := 0, len(occupied)
	for low < high {
		middle := (low + high) / 2
		if occupied[middle].last < pos {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

insert_occupied :: proc(table: ^[dynamic]Occupied, entry: Occupied) {
	inject_at(table, first_ending_at_or_after(table[:], entry.first), entry)
}

place :: proc(scan: ^Scan, vreg: Vreg, register: Register) {
	interval := &scan.live.intervals[vreg]
	table := &scan.occupancy[interval.class][register]
	scan.location[vreg] = register
	for range in interval.ranges {
		insert_occupied(table, Occupied{first = range.first, last = range.last, owner = vreg})
	}
	for edge_index := scan.edge_head[vreg]; edge_index != NO_EDGE; edge_index = scan.edges[edge_index].next {
		edge := &scan.edges[edge_index]
		if needs_extra(scan, edge, register) {
			insert_occupied(table, Occupied{first = edge.early, last = edge.early, owner = vreg})
		} else if input_register, ok := scan.location[edge.input].(Register); ok && input_register == register {
			scan.reuse_locked[edge.input] = true
		}
	}
}

unplace :: proc(scan: ^Scan, vreg: Vreg) {
	register := scan.location[vreg].(Register)
	table := &scan.occupancy[scan.live.intervals[vreg].class][register]
	for index := len(table) - 1; index >= 0; index -= 1 {
		if table[index].owner == vreg {
			ordered_remove(table, index)
		}
	}
	scan.location[vreg] = nil
}

spill :: proc(scan: ^Scan, vreg: Vreg) {
	scan.location[vreg] = Spill_Slot(scan.slot_count)
	scan.slot_count += 1
}

Verify_Entry :: struct {
	class:    Register_Class,
	register: Register,
	first:    Pos,
	last:     Pos,
	owner:    Vreg,
}

// verify checks `result` against `program` with its own liveness: every live
// vreg has a valid location; fixed operands sit in their registers; no two
// vregs live together share a register; no vreg lives in a register that an
// instruction it is live across destroys; and the inserted moves are exactly
// the reuse-input copies that differing locations need, with the def's
// register free at the copy.
verify :: proc(program: ^Program, result: ^Result, allocator := context.allocator) -> Error {
	live: Liveness
	if err := liveness(&live, program, allocator); err.kind != .None {
		return err
	}
	defer liveness_destroy(&live, allocator)
	context.allocator = allocator

	if len(result.location) != len(program.classes) {
		return Error{kind = .Bad_Location}
	}
	entries := make([dynamic]Verify_Entry)
	defer delete(entries)
	for &interval in live.intervals {
		if !interval_is_live(&interval) {
			continue
		}
		switch location in result.location[interval.vreg] {
		case nil:
			return Error{kind = .Bad_Location, vreg = interval.vreg}
		case Spill_Slot:
			if u32(location) >= result.spill_slot_count {
				return Error{kind = .Bad_Location, vreg = interval.vreg}
			}
		case Register:
			if int(location) not_in program.allocatable[interval.class] {
				return Error{kind = .Bad_Location, vreg = interval.vreg}
			}
			if int(location) in program.callee_saved[interval.class] && int(location) not_in result.callee_saved_used[interval.class] {
				return Error{kind = .Bad_Location, vreg = interval.vreg}
			}
			if int(location) in interval.clobbered {
				return Error{kind = .Clobber_Violated, vreg = interval.vreg}
			}
			for range in interval.ranges {
				append(&entries, Verify_Entry{interval.class, location, range.first, range.last, interval.vreg})
			}
		}
	}

	edges := make([dynamic]Reuse_Edge)
	defer delete(edges)
	for block, block_index in program.blocks {
		for instruction, index in block.instructions {
			for operand in instruction.operands {
				switch operand.constraint {
				case .Any:
				case .Fixed:
					register, is_register := result.location[operand.vreg].(Register)
					if !is_register || register != operand.fixed {
						return Error{kind = .Fixed_Violated, vreg = operand.vreg}
					}
				case .Reuse_Input:
					input := instruction.operands[operand.reuse].vreg
					if input != operand.vreg {
						append(
							&edges,
							Reuse_Edge {
								def = operand.vreg,
								input = input,
								early = live.starts[block_index] + Pos(POSITIONS_PER_INSTRUCTION * index),
								block = u32(block_index),
								index = u32(index),
							},
						)
					}
				}
			}
		}
	}
	expected := reuse_moves(edges[:], result.location)
	defer delete(expected)
	if !slice.equal(expected[:], result.inserted_moves) {
		return Error{kind = .Reuse_Violated}
	}
	for edge in edges {
		register, is_register := result.location[edge.def].(Register)
		if is_register && result.location[edge.input] != result.location[edge.def] && !interval_covers(&live.intervals[edge.def], edge.early) {
			append(&entries, Verify_Entry{live.intervals[edge.def].class, register, edge.early, edge.early, edge.def})
		}
	}

	slice.sort_by(entries[:], proc(a, b: Verify_Entry) -> bool {
		if a.class != b.class {
			return a.class < b.class
		}
		if a.register != b.register {
			return a.register < b.register
		}
		return a.first < b.first
	})
	reach: Pos
	reach_owner: Vreg
	for entry, index in entries {
		same_register := index > 0 && entries[index - 1].class == entry.class && entries[index - 1].register == entry.register
		if same_register && entry.first <= reach && entry.owner != reach_owner {
			return Error{kind = .Register_Conflict, vreg = entry.owner}
		}
		if !same_register || entry.last > reach {
			reach = entry.last
			reach_owner = entry.owner
		}
	}
	return Error{}
}

// resolve_edge_moves is the boundary of step E3: it turns each block's
// `edge_moves` into sequential moves between the locations of `result`,
// breaking cycles, and is the only place that will read them.
resolve_edge_moves :: proc(program: ^Program, result: ^Result, allocator := context.allocator) -> Error {
	return Error{}
}
