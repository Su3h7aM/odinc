package driver

import "core:path/filepath"
import "core:testing"

@(test)
directory_root_uses_package_file_selection :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, _ := filepath.join({#directory, "testdata", "root_directory"}, context.temp_allocator)
	session, error := check_program(root, directory, context.allocator, false)
	defer session_destroy(session)
	testing.expect_value(t, error, Driver_Error.None)
	for test_mode in ([]bool{false, true}) {
		options: Test_Options
		loaded, allocation_error := new(Session, context.allocator)
		if !testing.expect(t, allocation_error == nil) { return }
		loaded.allocator = context.allocator
		if test_mode { loaded.test_options = &options }
		defer session_destroy(loaded)
		package_id, _, _, load_error := load_main_package(loaded, root, directory, nil)
		if !testing.expect_value(t, load_error, Driver_Error.None) { continue }
		file_count := 0
		for file in loaded.files {
			if file == nil || file.package_id != package_id { continue }
			file_count += 1
			name := filepath.base(file.path)
			testing.expectf(
				t,
				name == "main.odin" ||
				name == "helper_linux_amd64.odin" ||
				name == "ignored_test.odin" ||
				(test_mode && (name == "tagged.odin" || name == "tagged_test.odin")),
				"unexpected file %s in test mode %v",
				name,
				test_mode,
			)
		}
		testing.expect_value(t, file_count, test_mode ? 5 : 3)
	}
}

@(test)
user_collections_load_and_reject_invalid_definitions :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, _ := filepath.join({#directory, "testdata", "user_collections", "app"}, context.temp_allocator)
	libraries, _ := filepath.join({#directory, "testdata", "user_collections", "libraries"}, context.temp_allocator)
	working_directory, _ := filepath.abs(".", context.temp_allocator)
	relative_libraries, _ := filepath.rel(working_directory, libraries, context.temp_allocator)
	collections := []Collection{{"nabla", relative_libraries}, {"other", libraries}}
	session, error := check_program(root, directory, context.allocator, false, collections)
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
