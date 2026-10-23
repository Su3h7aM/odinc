// Linear scan over whole-life intervals.
//
// Poletto & Sarkar (1999) scan the intervals in order of start and give each
// a register or a spill; Wimmer & Franz (2010) make the intervals hole-aware
// and allocate fixed (pre-coloured) ones first. This scan keeps, per register,
// a sorted table of the position ranges that are taken, so a vreg fits a
// register exactly when none of its ranges overlaps the table. When nothing
// fits, the cheapest set of vregs to spill (the candidate itself or the
// holders of one register) is spilled for its whole life; spill cost is
// loop-weighted references divided by interval length
// (docs/archive/research/06-pr7850-ir-regalloc-parallelism.md, section 2.4). No
// interval is split, so a spilled vreg stays in its slot and
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
NO_EDGE :: -1
NO_LINK :: -1

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

Hint_Link :: struct {
	partner: Vreg,
	next:    int,
}

Scan :: struct {
	program:        ^Program,
	live:           ^Liveness,
	location:       []Location,
	occupancy:      [Register_Class][REGISTER_LIMIT][dynamic]Occupied,
	edges:          [dynamic]Reuse_Edge,
	edge_head:      []int,
	hint_links:     [dynamic]Hint_Link,
	hint_head:      []int,
	fixed:          []Fixed_Requirement,
	reuse_locked:   []bool,
	conflict_seen:  []u32,
	conflict_stamp: u32,
	slot_count:     u32,
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
	scan.hint_head, _ = make([]int, vreg_count, allocator)
	scan.fixed, _ = make([]Fixed_Requirement, vreg_count, allocator)
	scan.reuse_locked, _ = make([]bool, vreg_count, allocator)
	scan.conflict_seen, _ = make([]u32, vreg_count, allocator)
	defer scan_destroy(&scan, allocator)
	if vreg_count > 0 &&
	   (scan.location == nil || scan.edge_head == nil || scan.hint_head == nil || scan.fixed == nil || scan.reuse_locked == nil || scan.conflict_seen == nil) {
		delete(scan.location, allocator)
		return {}, Error{kind = .Out_Of_Memory}
	}
	for vreg in 0 ..< vreg_count {
		scan.edge_head[vreg] = NO_EDGE
		scan.hint_head[vreg] = NO_LINK
	}

	if err = scan_prepare(&scan); err.kind != .None {
		delete(scan.location, allocator)
		return {}, err
	}

	order := make([dynamic]Vreg, allocator)
	defer delete(order)
	for &interval in live.intervals {
		if interval_is_live(&interval) {
			if _, append_err := append(&order, interval.vreg); append_err != nil {
				delete(scan.location, allocator)
				return {}, Error{kind = .Out_Of_Memory}
			}
		}
	}
	if err = sort_live_order(&live, order[:], allocator); err.kind != .None {
		delete(scan.location, allocator)
		return {}, err
	}

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
	moves, moves_err := reuse_moves(scan.edges[:], scan.location, allocator)
	if moves_err.kind != .None {
		delete(scan.location, allocator)
		return {}, moves_err
	}
	result.inserted_moves = moves[:]
	result.location = scan.location
	result.spill_slot_count = scan.slot_count
	if err = resolve_edge_moves(program, &result, allocator); err.kind != .None {
		result_destroy(&result, allocator)
		return {}, err
	}
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
	delete(scan.hint_links)
	delete(scan.hint_head, allocator)
	delete(scan.fixed, allocator)
	delete(scan.reuse_locked, allocator)
	delete(scan.conflict_seen, allocator)
}

ORDER_RADIX_BITS :: 16
ORDER_RADIX_BUCKETS :: 1 << ORDER_RADIX_BITS

// sort_live_order sorts `order` by first position, breaking ties by vreg,
// with a stable radix pass over the combined key. The key fits the order the
// scan needs, so no comparator runs.
sort_live_order :: proc(live: ^Liveness, order: []Vreg, allocator := context.allocator) -> Error {
	if len(order) < 2 {
		return {}
	}
	items := make([]u64, len(order), allocator)
	scratch := make([]u64, len(order), allocator)
	counts := make([]u32, ORDER_RADIX_BUCKETS, allocator)
	if items == nil || scratch == nil || counts == nil {
		delete(items, allocator)
		delete(scratch, allocator)
		delete(counts, allocator)
		return Error{kind = .Out_Of_Memory}
	}
	defer delete(items, allocator)
	defer delete(scratch, allocator)
	defer delete(counts, allocator)
	for vreg, index in order {
		items[index] = u64(interval_first(&live.intervals[vreg])) << 32 | u64(vreg)
	}
	source, destination := items, scratch
	for pass in 0 ..< 4 {
		shift := uint(pass * ORDER_RADIX_BITS)
		slice.fill(counts, 0)
		for item in source {
			counts[(item >> shift) & (ORDER_RADIX_BUCKETS - 1)] += 1
		}
		next := u32(0)
		for &count in counts {
			base := next
			next += count
			count = base
		}
		for item in source {
			bucket := (item >> shift) & (ORDER_RADIX_BUCKETS - 1)
			destination[counts[bucket]] = item
			counts[bucket] += 1
		}
		source, destination = destination, source
	}
	for item, index in source {
		order[index] = Vreg(item & 0xffff_ffff)
	}
	return {}
}

// scan_prepare collects fixed requirements, coalescing hints and reuse edges.
scan_prepare :: proc(scan: ^Scan) -> Error {
	program := scan.program
	link_hint :: proc(scan: ^Scan, vreg, partner: Vreg) -> bool {
		link := Hint_Link {
			partner = partner,
			next    = scan.hint_head[vreg],
		}
		scan.hint_head[vreg] = len(scan.hint_links)
		_, append_err := append(&scan.hint_links, link)
		return append_err == nil
	}
	set_hint :: proc(scan: ^Scan, a, b: Vreg) -> bool {
		if scan.program.classes[a] != scan.program.classes[b] {
			return true
		}
		return link_hint(scan, a, b) && link_hint(scan, b, a)
	}

	for block, block_index in program.blocks {
		for moves in block.edge_moves {
			for move in moves {
				if !set_hint(scan, move.source, move.destination) {
					return Error{kind = .Out_Of_Memory}
				}
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
					if _, append_err := append(&scan.edges, edge); append_err != nil {
						return Error{kind = .Out_Of_Memory}
					}
					if !set_hint(scan, operand.vreg, input) {
						return Error{kind = .Out_Of_Memory}
					}
				}
			}
			if instruction.is_move && len(instruction.operands) == 2 {
				if !set_hint(scan, instruction.operands[0].vreg, instruction.operands[1].vreg) {
					return Error{kind = .Out_Of_Memory}
				}
			}
		}
	}
	return Error{}
}

// reuse_moves lists the copies the reuse-input pairs need under `location`,
// in the order of `edges`, which is program order.
reuse_moves :: proc(edges: []Reuse_Edge, location: []Location, allocator := context.allocator) -> ([dynamic]Move_At, Error) {
	moves := make([dynamic]Move_At, allocator)
	for edge in edges {
		if location[edge.def] != location[edge.input] {
			if _, append_err := append(&moves, Move_At{block = edge.block, before = edge.index, move = Move{source = edge.input, destination = edge.def}});
			   append_err != nil {
				delete(moves)
				return nil, Error{kind = .Out_Of_Memory}
			}
		}
	}
	return moves, {}
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
		conflicts, err := has_conflict(scan, vreg, preferred[index], nil)
		if err.kind != .None {
			return err
		}
		if !conflicts {
			return place(scan, vreg, preferred[index])
		}
	}

	owners := make([dynamic]Vreg, context.temp_allocator)
	cheapest_owners := make([dynamic]Vreg, context.temp_allocator)
	cheapest_cost := COST_INFINITE
	cheapest_register := -1
	for index in 0 ..< count {
		clear(&owners)
		if _, err := has_conflict(scan, vreg, preferred[index], &owners); err.kind != .None {
			return err
		}
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
			if _, append_err := append(&cheapest_owners, ..owners[:]); append_err != nil {
				return Error{kind = .Out_Of_Memory, vreg = vreg}
			}
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
	return place(scan, vreg, Register(cheapest_register))
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

	for link_index := scan.hint_head[vreg]; link_index != NO_LINK; link_index = scan.hint_links[link_index].next {
		if register, ok := scan.location[scan.hint_links[link_index].partner].(Register); ok {
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
	tiers := [2]Register_Set{caller, callee}
	if interval.crosses_call {
		tiers = {callee, caller}
	}
	for tier in tiers {
		for register in tier {
			offer(register, allowed, &seen, order, &count)
		}
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
// `register`; with `owners` it also collects every distinct overlapped vreg,
// in table order. The occupancy table is sorted and overlap-free, so each
// range resumes its search where the previous one stopped, and a stamp per
// vreg replaces the linear membership test.
has_conflict :: proc(scan: ^Scan, vreg: Vreg, register: Register, owners: ^[dynamic]Vreg) -> (bool, Error) {
	interval := &scan.live.intervals[vreg]
	occupied := scan.occupancy[interval.class][register][:]
	if owners != nil {
		scan.conflict_stamp += 1
		if scan.conflict_stamp == 0 {
			slice.fill(scan.conflict_seen, 0)
			scan.conflict_stamp = 1
		}
	}
	check :: proc(
		scan: ^Scan,
		occupied: []Occupied,
		first, last: Pos,
		vreg: Vreg,
		owners: ^[dynamic]Vreg,
		start: int,
	) -> (
		next: int,
		found: bool,
		err: Error,
	) {
		next = first_ending_at_or_after(occupied, first, start)
		for index := next; index < len(occupied) && occupied[index].first <= last; index += 1 {
			owner := occupied[index].owner
			if owner == vreg {
				continue
			}
			if owners == nil {
				return next, true, {}
			}
			found = true
			if scan.conflict_seen[owner] != scan.conflict_stamp {
				scan.conflict_seen[owner] = scan.conflict_stamp
				if _, append_err := append(owners, owner); append_err != nil {
					return next, false, Error{kind = .Out_Of_Memory, vreg = vreg}
				}
			}
		}
		return next, found, {}
	}
	found := false
	start := 0
	for range in interval.ranges {
		next, overlaps, err := check(scan, occupied, range.first, range.last, vreg, owners, start)
		if err.kind != .None {
			return false, err
		}
		start = next
		if overlaps {
			if owners == nil {
				return true, {}
			}
			found = true
		}
	}
	for edge_index := scan.edge_head[vreg]; edge_index != NO_EDGE; edge_index = scan.edges[edge_index].next {
		edge := &scan.edges[edge_index]
		if !needs_extra(scan, edge, register) {
			continue
		}
		_, overlaps, err := check(scan, occupied, edge.early, edge.early, vreg, owners, 0)
		if err.kind != .None {
			return false, err
		}
		if overlaps {
			if owners == nil {
				return true, {}
			}
			found = true
		}
	}
	return found, {}
}

first_ending_at_or_after :: proc "contextless" (occupied: []Occupied, pos: Pos, from := 0) -> int {
	low, high := from, len(occupied)
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

insert_occupied :: proc(table: ^[dynamic]Occupied, entry: Occupied) -> Error {
	// Ranges arrive in ascending scan order and never overlap the table, so a
	// range always extends it; only a reuse-input extra point can land inside.
	if n := len(table); n == 0 || entry.first > table[n - 1].last {
		if _, err := append(table, entry); err != nil {
			return Error{kind = .Out_Of_Memory}
		}
		return {}
	}
	if len(table) == cap(table) {
		if reserve(table, max(2 * cap(table), 16)) != nil {
			return Error{kind = .Out_Of_Memory}
		}
	}
	if _, err := inject_at(table, first_ending_at_or_after(table[:], entry.first), entry); err != nil {
		return Error{kind = .Out_Of_Memory}
	}
	return {}
}

place :: proc(scan: ^Scan, vreg: Vreg, register: Register) -> Error {
	interval := &scan.live.intervals[vreg]
	table := &scan.occupancy[interval.class][register]
	scan.location[vreg] = register
	for range in interval.ranges {
		if err := insert_occupied(table, Occupied{first = range.first, last = range.last, owner = vreg}); err.kind != .None {
			return err
		}
	}
	for edge_index := scan.edge_head[vreg]; edge_index != NO_EDGE; edge_index = scan.edges[edge_index].next {
		edge := &scan.edges[edge_index]
		if needs_extra(scan, edge, register) {
			if err := insert_occupied(table, Occupied{first = edge.early, last = edge.early, owner = vreg}); err.kind != .None {
				return err
			}
		} else if input_register, ok := scan.location[edge.input].(Register); ok && input_register == register {
			scan.reuse_locked[edge.input] = true
		}
	}
	return {}
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
				if _, append_err := append(&entries, Verify_Entry{interval.class, location, range.first, range.last, interval.vreg}); append_err != nil {
					return Error{kind = .Out_Of_Memory, vreg = interval.vreg}
				}
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
						edge := Reuse_Edge {
							def   = operand.vreg,
							input = input,
							early = live.starts[block_index] + Pos(POSITIONS_PER_INSTRUCTION * index),
							block = u32(block_index),
							index = u32(index),
						}
						if _, append_err := append(&edges, edge); append_err != nil {
							return Error{kind = .Out_Of_Memory, vreg = operand.vreg}
						}
					}
				}
			}
		}
	}
	expected, expected_err := reuse_moves(edges[:], result.location)
	if expected_err.kind != .None {
		return expected_err
	}
	defer delete(expected)
	if !slice.equal(expected[:], result.inserted_moves) {
		return Error{kind = .Reuse_Violated}
	}
	for edge in edges {
		register, is_register := result.location[edge.def].(Register)
		if is_register && result.location[edge.input] != result.location[edge.def] && !interval_covers(&live.intervals[edge.def], edge.early) {
			if _, append_err := append(&entries, Verify_Entry{live.intervals[edge.def].class, register, edge.early, edge.early, edge.def}); append_err != nil {
				return Error{kind = .Out_Of_Memory, vreg = edge.def}
			}
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
