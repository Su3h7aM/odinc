package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
simd_maximum_reduction_preserves_numeric_lane_semantics :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "simd_reduce_max", 0)
}
