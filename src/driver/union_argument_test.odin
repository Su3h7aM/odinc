package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
explicit_union_argument_conversion_runs_once :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "union_argument", 42)
}
