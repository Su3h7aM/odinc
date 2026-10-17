// Sequential resolution of the parallel copies a block carries for one
// successor (ticket E3).
//
// The copies of an edge happen at once: every source is read before any
// destination is written, so running the list in order is wrong as soon as one
// copy overwrites a source another still reads. The order follows the
// destination rule: a copy runs first when no remaining copy reads its
// destination. When no copy qualifies the remaining ones form cycles; one
// source is saved in a temporary — the first register of `Program.scratch`, or
// a fresh spill slot when the source is memory — and every read of it switches
// to the temporary, which unblocks the cycle. One temporary is enough for a
// whole list: a temporary whose consumer is still waiting would leave an
// endless chain of reads behind it, and a stuck set holds no chain, so that
// consumer always runs before the next cycle can be broken.
//
// Every block with edge moves has exactly one successor — the edge block the
// selector creates for each CFG edge — and the copies are placed before its
// final instruction, the branch.
package regalloc

// resolve_edge_moves turns each block's `edge_moves` into the sequential copies
// of `result.edge_copies`, breaking cycles as above, and returns an error when
// a copy names a vreg without a location or mixes register classes. A result
// that already holds copies is left alone: `allocate` resolves the edge moves
// and a second call must not duplicate them.
resolve_edge_moves :: proc(program: ^Program, result: ^Result, allocator := context.allocator) -> Error {
	if result.edge_copies != nil {
		return Error{}
	}
	context.allocator = allocator
	copies := make([dynamic]Edge_Copy, allocator)
	resolved := false
	defer if !resolved { delete(copies) }
	pending := make([dynamic]Edge_Copy, context.temp_allocator)
	group := make([dynamic]Edge_Copy, context.temp_allocator)
	for block, block_index in program.blocks {
		for moves in block.edge_moves {
			if len(moves) == 0 || len(block.instructions) == 0 {
				continue
			}
			before := u32(len(block.instructions) - 1)
			clear(&pending)
			for move in moves {
				source, source_class, source_ok := location_of(program, result, move.source)
				destination, destination_class, destination_ok := location_of(program, result, move.destination)
				if !source_ok || !destination_ok {
					unknown := move.source if !source_ok else move.destination
					return Error{kind = .Bad_Location, vreg = unknown}
				}
				if source == destination {
					continue
				}
				if source_class != destination_class {
					return Error{kind = .Bad_Location, vreg = move.destination}
				}
				if err := add_copy(
					&pending,
					Edge_Copy{block = u32(block_index), before = before, class = source_class, source = source, destination = destination},
				); err.kind != .None {
					return err
				}
			}
			for class_index in 0 ..< REGISTER_CLASS_COUNT {
				clear(&group)
				for copy in pending {
					if copy.class == Register_Class(class_index) {
						if err := add_copy(&group, copy); err.kind != .None {
							return err
						}
					}
				}
				if err := resolve_copies(program, result, &copies, &group); err.kind != .None {
					return err
				}
			}
		}
	}
	result.edge_copies = copies[:]
	resolved = true
	return Error{}
}

// resolve_copies appends the sequential form of `group`'s simultaneous copies
// to `copies` and empties `group`.
resolve_copies :: proc(program: ^Program, result: ^Result, copies: ^[dynamic]Edge_Copy, group: ^[dynamic]Edge_Copy) -> Error {
	for len(group^) > 0 {
		if safe := first_safe(group[:]); safe >= 0 {
			if err := add_copy(copies, group[safe]); err.kind != .None {
				return err
			}
			ordered_remove(group, safe)
			continue
		}
		if err := break_cycle(program, result, copies, group); err.kind != .None {
			return err
		}
	}
	return Error{}
}

// first_safe is the index of the first copy no remaining copy reads the
// destination of, or -1 when every destination is read and only cycles remain.
first_safe :: proc "contextless" (group: []Edge_Copy) -> int {
	for move, index in group {
		if !is_read(group, move.destination) {
			return index
		}
	}
	return -1
}

// break_cycle saves the source of one copy of a cycle in a temporary and
// switches every read of it to the temporary.
break_cycle :: proc(program: ^Program, result: ^Result, copies: ^[dynamic]Edge_Copy, group: ^[dynamic]Edge_Copy) -> Error {
	for move in group^ {
		if !is_destination(group^[:], move.source) {
			continue
		}
		temporary := cycle_temporary(program, result, move.class, move.source)
		if err := add_copy(copies, Edge_Copy{block = move.block, before = move.before, class = move.class, source = move.source, destination = temporary});
		   err.kind != .None {
			return err
		}
		for &other in group^ {
			if other.source == move.source {
				other.source = temporary
			}
		}
		return Error{}
	}
	return Error{kind = .Bad_Location}
}

// cycle_temporary is where a cycle's source waits: the first reserved scratch
// register of the class when the source is a register, a fresh spill slot
// otherwise.
cycle_temporary :: proc(program: ^Program, result: ^Result, class: Register_Class, source: Location) -> Location {
	if _, is_register := source.(Register); is_register {
		for register in program.scratch[class] {
			return Register(register)
		}
	}
	slot := Spill_Slot(result.spill_slot_count)
	result.spill_slot_count += 1
	return slot
}

// location_of is where `vreg` lives and its register class.
location_of :: proc(program: ^Program, result: ^Result, vreg: Vreg) -> (location: Location, class: Register_Class, ok: bool) {
	if int(vreg) < len(program.classes) && int(vreg) < len(result.location) {
		location = result.location[vreg]
		class = program.classes[vreg]
		ok = location != nil
	}
	return
}

is_read :: proc "contextless" (group: []Edge_Copy, location: Location) -> bool {
	for move in group {
		if move.source == location {
			return true
		}
	}
	return false
}

is_destination :: proc "contextless" (group: []Edge_Copy, location: Location) -> bool {
	for move in group {
		if move.destination == location {
			return true
		}
	}
	return false
}

add_copy :: proc(target: ^[dynamic]Edge_Copy, copy: Edge_Copy) -> Error {
	if _, err := append(target, copy); err != nil {
		return Error{kind = .Out_Of_Memory}
	}
	return Error{}
}
