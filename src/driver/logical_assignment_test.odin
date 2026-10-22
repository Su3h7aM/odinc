package driver

import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oc:ir"
import "oc:lower"

@(test)
logical_compound_assignment_short_circuits_once :: proc(t: ^testing.T) {
	expect_exit(t, "logical_assignment", 42)
}

@(test)
logical_map_assignment_evaluates_key_per_access :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "logical_map_assignment", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator, false)
	defer session_destroy(session)
	if !testing.expect_value(t, err, Driver_Error.None) { return }
	module: ir.Module
	errors, lower_error := lower.lower_program(&session.program, &module, context.allocator)
	defer delete(errors)
	defer ir.module_destroy(&module)
	if !testing.expectf(t, lower_error == nil && len(errors) == 0, "%v %v", lower_error, errors) { return }
	calls := 0
	for function in module.functions {
		if function.name != main_symbol_name(session) { continue }
		for kind, index in function.nodes.kind[:len(function.nodes)] {
			if kind != .Call { continue }
			callee := ir.node_inputs(function, ir.Node_Id(index))[2]
			if function.nodes.kind[callee] != .Symbol_Addr { continue }
			symbol := function.nodes.data[callee].symbol
			if symbol.space == .Function && strings.contains(module.functions[symbol.index].name, "logical_map_key") { calls += 1 }
		}
	}
	testing.expect_value(t, calls, 4)
}
