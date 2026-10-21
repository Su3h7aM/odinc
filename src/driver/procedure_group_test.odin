package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
local_procedure_groups_native :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "local_procedure_groups", 10)
}
