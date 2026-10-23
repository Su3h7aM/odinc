package amd64

import "base:runtime"
import "core:mem/virtual"

// Renumbers the blocks of `function` so a block's successor follows it where possible, which lets
// the emitter fall through instead of jumping. The entry stays first and cold blocks go last.
// Selection numbers blocks in schedule order, so a block it splits off or an edge block it adds
// would otherwise sit far from the block it continues.
layout_blocks :: proc(function: ^Machine_Function) -> runtime.Allocator_Error {
	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch) or_return
	defer virtual.arena_destroy(&scratch)
	temp := virtual.arena_allocator(&scratch)

	count := len(function.blocks)
	order := make([dynamic]u32, 0, count, temp) or_return
	placed := make([]bool, count, temp) or_return
	unplaced_predecessors := make([]u32, count, temp) or_return
	for block in function.blocks {
		for successor in block.successors {
			unplaced_predecessors[successor] += 1
		}
	}

	for cold in ([2]bool{false, true}) {
		for seed in 0 ..< count {
			if placed[seed] || function.blocks[seed].cold != cold {
				continue
			}
			for current, found := u32(seed), true; found; current, found = best_successor(function, placed, unplaced_predecessors, current) {
				placed[current] = true
				append(&order, current) or_return
				for successor in function.blocks[current].successors {
					unplaced_predecessors[successor] -= 1
				}
			}
		}
	}

	position := make([]u32, count, temp) or_return
	for old, new in order {
		position[old] = u32(new)
	}
	reordered := make([]Machine_Block, count, temp) or_return
	for old, new in order {
		reordered[new] = function.blocks[old]
	}
	copy(function.blocks[:], reordered)
	for &block in function.blocks {
		for &successor in block.successors {
			successor = position[successor]
		}
		for instruction in block.instructions {
			for &operand in instruction.operands {
				if target, is_block := operand.(Block_Ref); is_block {
					operand = Block_Ref(position[target])
				}
			}
		}
	}
	return nil
}

// The unplaced successor of the same temperature to continue a chain with: the one deepest in
// loops, then the one with the fewest predecessors still unplaced, then the last listed, which is
// the fall-through target of a conditional branch.
@(private = "file")
best_successor :: proc(function: ^Machine_Function, placed: []bool, unplaced_predecessors: []u32, current: u32) -> (best: u32, found: bool) {
	cold := function.blocks[current].cold
	for candidate in function.blocks[current].successors {
		if placed[candidate] || function.blocks[candidate].cold != cold {
			continue
		}
		if !found {
			best, found = candidate, true
			continue
		}
		depth, best_depth := function.blocks[candidate].depth, function.blocks[best].depth
		if depth != best_depth {
			if depth > best_depth {
				best = candidate
			}
		} else if unplaced_predecessors[candidate] <= unplaced_predecessors[best] {
			best = candidate
		}
	}
	return
}
