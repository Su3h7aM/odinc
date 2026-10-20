package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
global_initializers_run_in_package_and_dependency_order :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "global_init_order", 143)
}

@(test)
init_procedures_run_after_their_package_dependencies_in_source_order :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "init_proc", 34)
}

@(test)
static_locals_keep_one_storage_across_calls :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "static_local", 85)
}
