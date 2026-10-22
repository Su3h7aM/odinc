package ir

import "core:testing"

@(private = "file")
Sample :: struct {
	fn:      ^Function,
	control: Node_Id,
	state:   Node_Id,
	cond:    Node_Id,
}

@(private = "file")
sample_make :: proc(t: ^testing.T) -> Sample {
	fn, err := function_make(context.allocator, 0, "sample", 0)
	testing.expect_value(t, err, nil)
	sample := Sample {
		fn = fn,
	}
	fn.start = add_node(fn, .Start, .Tuple)
	sample.control = add_node(fn, .Proj, .Control, {fn.start}, {index = 0})
	sample.state = add_node(fn, .Proj, .Memory, {fn.start}, {index = 1})
	sample.cond = add_node(fn, .Const_Int, .Bool, nil, {int_value = 1})
	return sample
}

@(private = "file")
branch :: proc(fn: ^Function, control, cond: Node_Id) -> (true_head, false_head: Node_Id) {
	split := add_node(fn, .If, .Tuple, {control, cond})
	true_head = add_node(fn, .Proj, .Control, {split}, {index = 0})
	false_head = add_node(fn, .Proj, .Control, {split}, {index = 1})
	return
}

@(test)
cfg_dominators_of_diamond :: proc(t: ^testing.T) {
	sample := sample_make(t)
	fn := sample.fn
	defer function_destroy(fn)

	true_head, false_head := branch(fn, sample.control, sample.cond)
	merge := add_node(fn, .Region, .Control, {true_head, false_head})
	ret := add_node(fn, .Return, .None, {merge, sample.state})
	fn.stop = add_node(fn, .Stop, .None, {ret})
	testing.expect_value(t, fn.error, nil)

	uses, uses_err := uses_build(fn, context.allocator)
	testing.expect_value(t, uses_err, nil)
	defer use_table_destroy(&uses, context.allocator)
	cfg, err := build_control_skeleton(fn, context.allocator, uses)
	testing.expect_value(t, err, nil)
	defer cfg_destroy(&cfg, context.allocator)

	testing.expect_value(t, len(cfg.heads), 4)
	entry := cfg.block_of[sample.control]
	left := cfg.block_of[true_head]
	right := cfg.block_of[false_head]
	join := cfg.block_of[merge]
	testing.expect_value(t, entry, Block_Id(0))
	testing.expect_value(t, join, Block_Id(3))
	testing.expect_value(t, cfg.idoms[entry], BLOCK_NONE)
	testing.expect_value(t, cfg.idoms[left], entry)
	testing.expect_value(t, cfg.idoms[right], entry)
	testing.expect_value(t, cfg.idoms[join], entry)
	testing.expect(t, dominates(cfg, entry, join) && !dominates(cfg, left, join))
	testing.expect_value(t, len(block_succs(cfg, entry)), 2)
	testing.expect_value(t, block_succs(cfg, entry)[0], left)
	testing.expect_value(t, block_succs(cfg, entry)[1], right)
	testing.expect_value(t, len(block_preds(cfg, join)), 2)
	testing.expect_value(t, block_preds(cfg, join)[0], left)
	testing.expect_value(t, block_preds(cfg, join)[1], right)
	testing.expect_value(t, cfg.exits[join], ret)
	testing.expect_value(t, cfg.exits[left], NODE_NONE)
	testing.expect_value(t, cfg.exit_counts[left], 1)
	testing.expect_value(t, block_of_node(cfg, fn, ret), join)
	testing.expect_value(t, len(cfg.loops), 0)
}

@(test)
cfg_loops_of_nested_loop :: proc(t: ^testing.T) {
	sample := sample_make(t)
	fn := sample.fn
	defer function_destroy(fn)

	outer := add_node(fn, .Loop, .Control, {sample.control, NODE_NONE})
	outer_body, outer_exit := branch(fn, outer, sample.cond)
	inner := add_node(fn, .Loop, .Control, {outer_body, NODE_NONE})
	inner_body, inner_exit := branch(fn, inner, sample.cond)
	set_input(fn, inner, 1, inner_body)
	set_input(fn, outer, 1, inner_exit)
	ret := add_node(fn, .Return, .None, {outer_exit, sample.state})
	fn.stop = add_node(fn, .Stop, .None, {ret})
	testing.expect_value(t, fn.error, nil)

	uses, uses_err := uses_build(fn, context.allocator)
	testing.expect_value(t, uses_err, nil)
	defer use_table_destroy(&uses, context.allocator)
	cfg, err := build_control_skeleton(fn, context.allocator, uses)
	testing.expect_value(t, err, nil)
	defer cfg_destroy(&cfg, context.allocator)

	testing.expect_value(t, len(cfg.heads), 7)
	outer_block := cfg.block_of[outer]
	inner_block := cfg.block_of[inner]
	outer_body_block := cfg.block_of[outer_body]
	outer_exit_block := cfg.block_of[outer_exit]
	inner_body_block := cfg.block_of[inner_body]
	inner_exit_block := cfg.block_of[inner_exit]
	testing.expect_value(t, cfg.idoms[outer_block], cfg.block_of[sample.control])
	testing.expect_value(t, cfg.idoms[outer_exit_block], outer_block)
	testing.expect_value(t, cfg.idoms[inner_block], outer_body_block)
	testing.expect_value(t, cfg.idoms[inner_exit_block], inner_block)

	testing.expect_value(t, len(cfg.loops), 2)
	testing.expect_value(t, cfg.loops[0], Loop_Info{outer_block, inner_exit_block, LOOP_NONE, 1})
	testing.expect_value(t, cfg.loops[1], Loop_Info{inner_block, inner_body_block, 0, 2})
	testing.expect_value(t, cfg.depths[cfg.block_of[sample.control]], 0)
	testing.expect_value(t, cfg.depths[outer_exit_block], 0)
	testing.expect_value(t, cfg.depths[outer_block], 1)
	testing.expect_value(t, cfg.depths[outer_body_block], 1)
	testing.expect_value(t, cfg.depths[inner_exit_block], 1)
	testing.expect_value(t, cfg.depths[inner_body_block], 2)
	testing.expect_value(t, cfg.loop_of[outer_body_block], Loop_Index(0))
	testing.expect_value(t, cfg.loop_of[inner_body_block], Loop_Index(1))
}

@(test)
cfg_loop_without_exit :: proc(t: ^testing.T) {
	sample := sample_make(t)
	fn := sample.fn
	defer function_destroy(fn)

	spin := add_node(fn, .Loop, .Control, {sample.control, NODE_NONE})
	set_input(fn, spin, 1, spin)
	fn.stop = add_node(fn, .Stop, .None)
	testing.expect_value(t, fn.error, nil)

	uses, uses_err := uses_build(fn, context.allocator)
	testing.expect_value(t, uses_err, nil)
	defer use_table_destroy(&uses, context.allocator)
	cfg, err := build_control_skeleton(fn, context.allocator, uses)
	testing.expect_value(t, err, nil)
	defer cfg_destroy(&cfg, context.allocator)

	spin_block := cfg.block_of[spin]
	testing.expect_value(t, len(cfg.heads), 2)
	testing.expect_value(t, cfg.exits[spin_block], NODE_NONE)
	testing.expect_value(t, len(block_succs(cfg, spin_block)), 1)
	testing.expect_value(t, block_succs(cfg, spin_block)[0], spin_block)
	testing.expect_value(t, cfg.loops[0], Loop_Info{spin_block, spin_block, LOOP_NONE, 1})
	testing.expect_value(t, cfg.depths[spin_block], 1)
}
