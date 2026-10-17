package lower

import "core:testing"
import "oc:check"
import "oc:ir"

@(test)
lower_unreachable_emits_an_ir_terminator :: proc(t: ^testing.T) {
	function, function_error := ir.function_make(context.allocator, 0, "main", 0)
	if !testing.expect_value(t, function_error, nil) { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{cc = .C})
	entry := ir.start(function)
	builder, builder_error := ir.builder_make(context.allocator, function, entry)
	if !testing.expect_value(t, builder_error, nil) { return }
	defer ir.builder_destroy(builder)
	program: check.Checked_Program
	builtin_kinds: [11]check.Builtin_Kind
	builtin_kinds[int(check.UNIVERSE_UNREACHABLE)] = .Unreachable
	program.builtin_kinds = builtin_kinds[:]
	job := Procedure_Job {
		program  = &program,
		function = function,
	}
	state := Procedure_State {
		job     = &job,
		builder = builder,
	}
	result := lower_builtin(&state, 0, {}, check.Builtin_Plan{builtin = check.UNIVERSE_UNREACHABLE})
	if !testing.expect(t, result == 0 && builder.control == 0) { return }
	if !testing.expect_value(t, ir.builder_finish(builder), nil) { return }
	terminators := 0
	for id in 1 ..< len(function.nodes) {
		if function.nodes.kind[id] == .Unreachable { terminators += 1 }
	}
	testing.expect_value(t, terminators, 1)
}
