package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
union_status_propagation_tests_the_value_not_its_address :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "union_propagation", 42)
}
