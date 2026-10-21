package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
global_address_literals_survive_until_fini :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "fini_handlers", 8)
}
