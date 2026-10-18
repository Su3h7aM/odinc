package driver

import "core:path/filepath"
import "core:testing"

@(test)
relative_import_and_alias_bind_package_members :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "package_imports", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.None)
}

@(test)
implicit_runtime_loads_for_trivial_program :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "implicit_runtime", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.None)
}

@(test)
import_cycle_is_located_and_fails_the_build :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "import_cycle", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.Import_Cycle)
}
