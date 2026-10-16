package ir

import "core:testing"

@(test)
graph_edits_and_uses :: proc(t: ^testing.T) {
	fn, make_err := function_make(context.allocator, 0, "sample", 0)
	testing.expect_value(t, make_err, nil)
	defer function_destroy(fn)

	fn.start = add_node(fn, .Start, .Tuple)
	control := add_node(fn, .Proj, .Control, {fn.start}, {index = 0})
	state := add_node(fn, .Proj, .Memory, {fn.start}, {index = 1})
	five := add_node(fn, .Const_Int, .I64, nil, {int_value = 5})
	sum := add_node(fn, .Add, .I64, {five, five})
	loop := add_node(fn, .Loop, .Control, {control, NODE_NONE})
	unused := add_node(fn, .Const_Float, .F64, nil, {float_bits = 1})
	ret := add_node(fn, .Return, .None, {control, state, sum})
	fn.stop = add_node(fn, .Stop, .None, {ret})

	testing.expect_value(t, fn.error, nil)
	testing.expect_value(t, len(fn.nodes), 10)
	testing.expect_value(t, node_int_value(fn, five), 5)
	testing.expect_value(t, node_index(fn, state), 1)
	testing.expect_value(t, node_input(fn, ret, 2), sum)

	remove_node(fn, unused)
	testing.expect_value(t, fn.nodes.kind[unused], Node_Kind.Removed)
	testing.expect_value(t, len(node_inputs(fn, unused)), 0)

	uses, err := uses_build(fn, context.allocator)
	testing.expect_value(t, err, nil)
	defer use_table_destroy(&uses, context.allocator)

	testing.expect_value(t, len(uses_of(uses, five)), 2)
	testing.expect_value(t, uses_of(uses, five)[0], Use{sum, 0})
	testing.expect_value(t, uses_of(uses, five)[1], Use{sum, 1})
	testing.expect_value(t, len(uses_of(uses, control)), 2)
	testing.expect_value(t, uses_of(uses, control)[0], Use{loop, 0})
	testing.expect_value(t, uses_of(uses, control)[1], Use{ret, 0})
	testing.expect_value(t, len(uses_of(uses, NODE_NONE)), 0)
	testing.expect_value(t, len(uses_of(uses, loop)), 0)
}
