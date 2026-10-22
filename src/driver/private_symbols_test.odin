package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
file_private_procedures_and_globals_keep_distinct_storage :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "file_private_symbols", 42)
}
