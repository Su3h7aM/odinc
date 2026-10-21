package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
simd_values_cross_procedure_abi :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "simd_abi", 63)
}
