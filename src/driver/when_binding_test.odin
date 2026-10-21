package driver

import "core:path/filepath"
import "core:testing"
import "oc:check"

@(test)
when_condition_resolves_from_later_sibling_when :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "when_retry", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.None)
}

@(test)
when_condition_never_declared_reports_check_failure :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "when_unresolved", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.Check_Failed)
}

@(test)
when_condition_evaluates_exists_directive_relative_to_file :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "exists_directive", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.None)
	testing.expect(t, !session.unresolved_when.set)
}

@(test)
core_thread_no_crt_constant_is_bound :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "core_thread_probe", "main.odin"}, context.temp_allocator)
	session, _ := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	found := false
	for package_value in session.packages {
		if package_value.name != "thread" { continue }
		found = true
		scope := check.scope_get(&session.scopes, package_value.scope)
		testing.expect(t, "_IS_SUPPORTED" in scope.lookup)
	}
	testing.expect(t, found)
}
