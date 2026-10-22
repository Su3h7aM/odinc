package ir

import "core:testing"

// Identical pure constructions share one node; anything else stays distinct, and sharing
// survives the `loop_collapse` rebuild.
@(test)
builder_interns_pure_nodes :: proc(t: ^testing.T) {
	fn, make_err := function_make(context.allocator, 0, "intern", 0)
	testing.expect_value(t, make_err, nil)
	defer function_destroy(fn)

	add_signature(fn, Signature{cc = .C, params = {{type = .I64}, {type = .Bool}}, results = {{type = .I64}}})
	entry := start(fn)
	before := len(fn.nodes)

	zero := const_int(fn, .I64, 0)
	testing.expect_value(t, const_int(fn, .I64, 0), zero)
	testing.expect_value(t, len(fn.nodes), before + 1)

	one := const_int(fn, .I64, 1)
	testing.expect(t, one != zero)
	testing.expect(t, const_int(fn, .I32, 0) != zero)
	testing.expect_value(t, const_float(fn, .F64, 0), const_float(fn, .F64, 0))
	testing.expect_value(t, undef(fn, .I64), undef(fn, .I64))
	testing.expect(t, undef(fn, .I32) != undef(fn, .I64))
	testing.expect_value(t, symbol_addr(fn, {.Global, 0}), symbol_addr(fn, {.Global, 0}))
	testing.expect(t, symbol_addr(fn, {.Global, 1}) != symbol_addr(fn, {.Global, 0}))
	testing.expect(t, tls_addr(fn, {.Global, 0}) != symbol_addr(fn, {.Global, 0}))

	sum := binary(fn, .Add, zero, one)
	testing.expect_value(t, binary(fn, .Add, one, zero), sum)
	testing.expect(t, binary(fn, .Sub, zero, one) != binary(fn, .Sub, one, zero))
	testing.expect_value(t, compare(fn, .Eq, zero, one), compare(fn, .Eq, one, zero))
	small := const_int(fn, .I32, 0)
	testing.expect_value(t, convert(fn, .Zext, small, .I64), convert(fn, .Zext, small, .I64))
	testing.expect(t, convert(fn, .Sext, small, .I64) != convert(fn, .Zext, small, .I64))
	testing.expect_value(t, select(fn, entry.params[1], zero, one), select(fn, entry.params[1], zero, one))

	base := symbol_addr(fn, {.Global, 2})
	testing.expect_value(t, ptr_offset(fn, base, 8), ptr_offset(fn, base, 8))
	testing.expect(t, ptr_offset(fn, base, 16) != ptr_offset(fn, base, 8))

	first := divide(fn, .SDiv, entry.control, entry.params[0], one)
	testing.expect(t, divide(fn, .SDiv, entry.control, entry.params[0], one) != first)
	total := binary(fn, .Add, first, first)

	b, builder_err := builder_make(context.allocator, fn, entry)
	testing.expect_value(t, builder_err, nil)
	defer builder_destroy(b)

	target := jump_target_make(b)
	spin := loop_begin(b, nil)
	jump_to(b, target)
	loop_end(b, spin)
	testing.expect(t, fn.nodes.kind[spin.loop] == .Removed)
	testing.expect(t, seal_target(b, target))
	emit_return(b, total)
	testing.expect_value(t, builder_finish(b), nil)

	testing.expect_value(t, const_int(fn, .I64, 0), zero)
	testing.expect_value(t, binary(fn, .Add, zero, one), sum)
}
