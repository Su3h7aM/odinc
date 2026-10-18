package driver

import "core:path/filepath"
import "core:testing"

@(test)
directory_root_uses_package_file_selection :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, _ := filepath.join({#directory, "testdata", "root_directory"}, context.temp_allocator)
	session, error := check_program(root, directory, context.allocator)
	defer session_destroy(session)
	testing.expect_value(t, error, Driver_Error.None)
}

@(test)
user_collections_load_and_reject_invalid_definitions :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, _ := filepath.join({#directory, "testdata", "user_collections", "app"}, context.temp_allocator)
	libraries, _ := filepath.join({#directory, "testdata", "user_collections", "libraries"}, context.temp_allocator)
	working_directory, _ := filepath.abs(".", context.temp_allocator)
	relative_libraries, _ := filepath.rel(working_directory, libraries, context.temp_allocator)
	collections := []Collection{{"nabla", relative_libraries}, {"other", libraries}}
	session, error := check_program(root, directory, context.allocator, collections)
	defer session_destroy(session)
	testing.expect_value(t, error, Driver_Error.None)
	table: Collection_Table
	testing.expect_value(t, collection_table_init(&table, root, context.allocator), Collection_Error.None)
	defer collection_table_destroy(&table)
	for name in ([]string{"", "_", "system", "1name", "bad-name", "bad/name"}) {
		testing.expect_value(t, collection_add(&table, name, libraries), Collection_Error.Invalid_Collection)
	}
	for name in ([]string{"base", "core", "vendor"}) {
		testing.expect_value(t, collection_add(&table, name, libraries), Collection_Error.Duplicate_Collection)
	}
	testing.expect_value(t, collection_add(&table, "nabla", libraries), Collection_Error.None)
	testing.expect_value(t, collection_add(&table, "δοκιμή2", libraries), Collection_Error.None)
	testing.expect_value(t, collection_add(&table, "nabla", directory), Collection_Error.Duplicate_Collection)
	testing.expect_value(t, collection_add(&table, "missing", "does-not-exist"), Collection_Error.Missing_Directory)
	file, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	testing.expect_value(t, collection_add(&table, "file", file), Collection_Error.Missing_Directory)
}
