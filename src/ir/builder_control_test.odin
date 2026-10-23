package ir

import "core:testing"

// Roughly:
//
//	f :: proc(n, k: i64, p: ^i64) -> i64 {
//		i, sum := 0, 0
//		outer: for ; i < n; i += 1 {
//			for j := 0; j < n; j += 1 {
//				if j == k { continue outer }
//				switch j {
//				case 0: p^ = 1; sum += 1; fallthrough
//				case 1: sum += 2
//				}
//			}
//		}
//		for { break }
//		return sum
//	}
@(test)
builder_control_nested_loops :: proc(t: ^testing.T) {
	fn, make_err := function_make(context.allocator, 0, "main.f", 0)
	testing.expect_value(t, make_err, nil)
	defer function_destroy(fn)

	add_signature(fn, Signature{cc = .C, params = {{type = .I64}, {type = .I64}, {type = .Ptr}}, results = {{type = .I64}}})
	entry := start(fn)
	n, k, p := entry.params[0], entry.params[1], entry.params[2]
	b, builder_err := builder_make(context.allocator, fn, entry)
	testing.expect_value(t, builder_err, nil)
	defer builder_destroy(b)

	zero, one, two := const_int(fn, .I64, 0), const_int(fn, .I64, 1), const_int(fn, .I64, 2)
	i := variable_declare(b, zero)
	sum := variable_declare(b, zero)
	outer_variables := len(b.values)

	outer_break := jump_target_make(b)
	outer := loop_begin(b, {i, sum})
	outer_continue := jump_target_make(b)
	exit := branch_if(b, compare(fn, .SLt, variable_get(b, i), n))
	enter_arm(b, exit, 1)
	jump_to(b, outer_break)
	enter_arm(b, exit, 0)

	j := variable_declare(b, zero)
	inner_break := jump_target_make(b)
	inner := loop_begin(b, {j, sum})
	inner_continue := jump_target_make(b)
	exit = branch_if(b, compare(fn, .SLt, variable_get(b, j), n))
	enter_arm(b, exit, 1)
	jump_to(b, inner_break)
	enter_arm(b, exit, 0)

	skip := branch_if(b, compare(fn, .Eq, variable_get(b, j), k))
	enter_arm(b, skip, 0)
	jump_to(b, outer_continue)
	enter_arm(b, skip, 1)

	cases := branch_switch(b, variable_get(b, j), {0, 1})
	switch_end := jump_target_make(b)
	second_case := jump_target_make(b)
	enter_arm(b, cases, 0)
	variable_set(b, MEMORY_VARIABLE, store(fn, b.control, variable_get(b, MEMORY_VARIABLE), p, one, 3))
	variable_set(b, sum, binary(fn, .Add, variable_get(b, sum), one))
	jump_to(b, second_case)
	enter_arm(b, cases, 1)
	jump_to(b, second_case)
	testing.expect(t, seal_target(b, second_case))
	variable_set(b, sum, binary(fn, .Add, variable_get(b, sum), two))
	jump_to(b, switch_end)
	enter_arm(b, cases, 2)
	jump_to(b, switch_end)
	testing.expect(t, seal_target(b, switch_end))

	jump_to(b, inner_continue)
	testing.expect(t, seal_target(b, inner_continue))
	variable_set(b, j, binary(fn, .Add, variable_get(b, j), one))
	loop_end(b, inner)
	testing.expect(t, seal_target(b, inner_break))
	variables_truncate(b, outer_variables)

	jump_to(b, outer_continue)
	testing.expect(t, seal_target(b, outer_continue))
	variable_set(b, i, binary(fn, .Add, variable_get(b, i), one))
	loop_end(b, outer)
	testing.expect(t, seal_target(b, outer_break))

	spin_break := jump_target_make(b)
	spin := loop_begin(b, nil)
	jump_to(b, spin_break)
	loop_end(b, spin)
	testing.expect(t, fn.nodes.kind[spin.loop] == .Removed)
	testing.expect(t, seal_target(b, spin_break))
	emit_return(b, variable_get(b, sum))

	testing.expect_value(t, builder_finish(b), nil)

	loops, regions, phis := 0, 0, 0
	for id in 1 ..< len(fn.nodes) {
		#partial switch fn.nodes.kind[id] {
		case .Loop:
			loops += 1
		case .Region:
			regions += 1
		case .Phi:
			phis += 1
		}
	}
	testing.expect_value(t, loops, 2)
	testing.expect_value(t, regions, 3)
	testing.expect_value(t, phis, 3 + 3 + 2 + 2)

	uses, uses_err := uses_build(fn, context.allocator)
	testing.expect_value(t, uses_err, nil)
	defer use_table_destroy(&uses, context.allocator)
	cfg, cfg_err := build_control_skeleton(fn, context.allocator, uses, context.temp_allocator)
	testing.expect_value(t, cfg_err, nil)
	defer cfg_destroy(&cfg, context.allocator)
	testing.expect_value(t, len(cfg.loops), 2)
	testing.expect_value(t, cfg.loops[0].depth, 1)
	testing.expect_value(t, cfg.loops[1].depth, 2)
	testing.expect_value(t, cfg.loops[1].parent, Loop_Index(0))

}
