package sched

import "core:strings"
import "core:testing"
import ir "oc:ir"

// `add_or_zero(a, b: i64, c: bool) -> i64`: a diamond with one arm computing `a + b` and the
// other a constant, merged by a value and a memory phi.
@(private = "package")
Diamond :: struct {
	fn:         ^ir.Function,
	true_head:  ir.Node_Id,
	false_head: ir.Node_Id,
	sum:        ir.Node_Id,
}

@(private = "package")
diamond_make :: proc(t: ^testing.T) -> Diamond {
	fn, make_err := ir.function_make(context.allocator, 0, "main.add_or_zero", 0)
	testing.expect_value(t, make_err, nil)

	signature := ir.add_signature(fn, ir.Signature{cc = .C, params = {{type = .I64}, {type = .I64}, {type = .Bool, ext = .Zero}}, results = {{type = .I64}}})
	testing.expect_value(t, signature, fn.signature)

	entry := ir.start(fn)
	true_head, false_head := ir.if_(fn, entry.control, entry.params[2])
	sum := ir.binary(fn, .Add, entry.params[0], entry.params[1])
	merge := ir.region(fn, {true_head, false_head})
	zero := ir.const_int(fn, .I64, 0)
	value := ir.phi(fn, merge, {sum, zero})
	state := ir.phi(fn, merge, {entry.memory, entry.memory})
	ir.ret(fn, merge, state, value)
	testing.expect_value(t, ir.function_finish(fn), nil)
	return Diamond{fn = fn, true_head = true_head, false_head = false_head, sum = sum}
}

@(test)
print_diamond_schedule_golden :: proc(t: ^testing.T) {
	diamond := diamond_make(t)
	fn := diamond.fn
	defer ir.function_destroy(fn)

	schedule, order_err := order(fn, context.allocator)
	testing.expect_value(t, order_err, nil)
	defer schedule_destroy(&schedule, context.allocator)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	testing.expect_value(t, print_schedule(strings.to_writer(&builder), fn, schedule), nil)

	expected := `func f0 "main.add_or_zero" sched {
  block b0 head=n2 depth=0 preds=[] succs=[b2,b1]
    n3 = proj.mem n1 index=1
    n6 = proj.bool n1 index=4
    n7 = if.tuple n2, n6
  block b1 head=n9 depth=0 preds=[b0] succs=[b3]
  block b2 head=n8 depth=0 preds=[b0] succs=[b3]
    n4 = proj.i64 n1 index=2
    n5 = proj.i64 n1 index=3
    n10 = add.i64 n4, n5
  block b3 head=n11 depth=0 preds=[b2,b1] succs=[]
    n13 = phi.i64 n11, n10, n12
    n14 = phi.mem n11, n3, n3
    n15 = return.none n11, n14, n13
}
`
	testing.expect_value(t, strings.to_string(builder), expected)
}
