package driver

import "core:os"
import "core:testing"

@(test)
collection_resolution_table :: proc(t: ^testing.T) {
	allocator := context.allocator
	root, root_err := os.make_directory_temp("", "odin-collections-*", allocator)
	testing.expect(t, root_err == nil)
	defer delete(root, allocator)
	defer os.remove_all(root)
	directories := []string{"base", "core", "vendor", "user", "app", "base/runtime", "core/fmt", "user/lib", "app/sub"}
	for directory in directories {
		path, err := os.join_path({root, directory}, allocator)
		testing.expect(t, err == nil)
		defer delete(path, allocator)
		testing.expect(t, os.make_directory_all(path) == nil)
	}

	table: Collection_Table
	testing.expect(t, collection_table_init(&table, root, allocator) == .None)
	defer collection_table_destroy(&table)
	user_path, path_err := os.join_path({root, "user"}, allocator)
	testing.expect(t, path_err == nil)
	defer delete(user_path, allocator)
	testing.expect(t, collection_add(&table, "user", user_path) == .None)
	collection_table_freeze(&table)

	app_path, app_path_err := os.join_path({root, "app"}, allocator)
	testing.expect(t, app_path_err == nil)
	defer delete(app_path, allocator)
	cases := []struct {
		import_path, importer, expected: string,
	} {
		{"core:fmt", root, "core/fmt"},
		{"base:runtime", root, "base/runtime"},
		{"vendor:.", root, "vendor"},
		{"user:lib", root, "user/lib"},
		{"sub", app_path, "app/sub"},
	}
	for test_case in cases {
		resolved, err := resolve_collection_import(&table, test_case.import_path, test_case.importer, allocator)
		expected, join_err := os.join_path({root, test_case.expected}, allocator)
		testing.expect(t, join_err == nil)
		testing.expect(t, err == .None && resolved == expected)
		delete(resolved, allocator)
		delete(expected, allocator)
	}
	_, unknown_err := resolve_collection_import(&table, "nope:pkg", root, allocator)
	testing.expect(t, unknown_err == .Unknown_Collection)
	_, escape_err := resolve_collection_import(&table, "user:../core", root, allocator)
	testing.expect(t, escape_err == .Path_Escapes_Root)
}
