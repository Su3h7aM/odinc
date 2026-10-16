package sched

import "core:testing"
import ir "oc:ir"

@(private = "file")
has_schedule_code :: proc(errors: []Schedule_Error, code: Schedule_Code) -> bool {
	for error in errors {
		if error.code == code {
			return true
		}
	}
	return false
}

@(test)
verify_rejects_definition_outside_its_dominator :: proc(t: ^testing.T) {
	diamond := diamond_make(t)
	fn := diamond.fn
	defer ir.function_destroy(fn)

	schedule, order_err := order(fn, context.allocator)
	testing.expect_value(t, order_err, nil)
	defer schedule_destroy(&schedule, context.allocator)

	errors, verify_err := verify(fn, schedule, context.allocator)
	testing.expect_value(t, verify_err, nil)
	testing.expect_value(t, len(errors), 0)
	delete(errors, context.allocator)

	// Move the definition of `sum` into the false arm. The merged phi still reads it on the
	// true arm, so the definition no longer dominates that use.
	true_block := &schedule.blocks[2]
	testing.expect_value(t, true_block.head, diamond.true_head)
	false_block := &schedule.blocks[1]
	testing.expect_value(t, false_block.head, diamond.false_head)
	testing.expect_value(t, true_block.nodes[len(true_block.nodes) - 1], diamond.sum)
	false_block.nodes = true_block.nodes[len(true_block.nodes) - 1:]
	true_block.nodes = true_block.nodes[:len(true_block.nodes) - 1]
	schedule.placement[diamond.sum] = false_block.id

	errors, verify_err = verify(fn, schedule, context.allocator)
	testing.expect_value(t, verify_err, nil)
	testing.expect(t, has_schedule_code(errors, .Use_Not_Dominated), "expected Use_Not_Dominated")
	delete(errors, context.allocator)
}
