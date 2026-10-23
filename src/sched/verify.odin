package sched

import "base:runtime"
import ir "oc:ir"

Schedule_Code :: enum u8 {
	None,
	Placed_Twice,
	Phi_After_Value,
	Use_Not_Dominated,
}

Schedule_Error :: struct {
	node:  ir.Node_Id,
	other: ir.Node_Id,
	code:  Schedule_Code,
}

// Checks D2 of `docs/archive/02-ir-design.md` section 9: no node is placed twice, phis lead their
// block, and every use is in a block the definition dominates. For a phi the use block is the
// predecessor block matching the value's input slot. Rematerialized values are not placed and
// are materialized at each use, so they are exempt. The caller frees the returned slice.
verify :: proc(fn: ^ir.Function, schedule: Schedule, allocator: runtime.Allocator) -> (errors: []Schedule_Error, err: runtime.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temp := context.temp_allocator

	found := make([dynamic]Schedule_Error, allocator) or_return
	defer if err != nil {
		delete(found)
	}

	seen := make([]u8, len(fn.nodes), temp) or_return
	for block in schedule.blocks {
		saw_value := false
		for id in block.nodes {
			seen[id] += 1
			if seen[id] == 2 {
				report(&found, id, block.head, .Placed_Twice) or_return
			}
			if fn.nodes.kind[id] == .Phi {
				if saw_value {
					report(&found, id, block.head, .Phi_After_Value) or_return
				}
			} else {
				saw_value = true
			}
		}
	}

	for user in schedule.ordered {
		for slot in 0 ..< int(fn.nodes.input_count[user]) {
			def := ir.node_input(fn, user, slot)
			if def == ir.NODE_NONE || fn.nodes.type[def] == .Control {
				continue
			}
			def_block := placed_block(fn, schedule, def)
			if def_block == ir.BLOCK_NONE {
				continue
			}
			use_block := placed_block(fn, schedule, user)
			if fn.nodes.kind[user] == .Phi {
				use_block = phi_value_block(fn, schedule, user, slot)
			}
			if use_block == ir.BLOCK_NONE {
				continue
			}
			if !ir.dominates(schedule.cfg, def_block, use_block) {
				report(&found, user, def, .Use_Not_Dominated) or_return
			}
		}
	}
	return found[:], nil
}

@(private = "file")
report :: proc(found: ^[dynamic]Schedule_Error, node, other: ir.Node_Id, code: Schedule_Code) -> runtime.Allocator_Error {
	_, err := append(found, Schedule_Error{node = node, other = other, code = code})
	return err
}

@(private = "file")
placed_block :: proc(fn: ^ir.Function, schedule: Schedule, id: ir.Node_Id) -> ir.Block_Id {
	if schedule.placement[id] != ir.BLOCK_NONE {
		return schedule.placement[id]
	}
	return ir.block_of_node(schedule.cfg, fn, id)
}

// A phi reads value input `slot` at the end of the predecessor block matching region input
// `slot - 1`.
@(private = "file")
phi_value_block :: proc(fn: ^ir.Function, schedule: Schedule, phi: ir.Node_Id, slot: int) -> ir.Block_Id {
	region := ir.node_input(fn, phi, 0)
	if fn.nodes.kind[region] != .Region && fn.nodes.kind[region] != .Loop {
		return ir.BLOCK_NONE
	}
	predecessor_slot := slot - 1
	if predecessor_slot < 0 || predecessor_slot >= int(fn.nodes.input_count[region]) {
		return ir.BLOCK_NONE
	}
	return schedule.cfg.block_of[ir.node_input(fn, region, predecessor_slot)]
}
