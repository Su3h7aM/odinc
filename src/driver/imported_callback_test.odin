package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
imported_procedure_values_keep_their_entry_address :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "imported_callback", 42)
}
