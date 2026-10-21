package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

// A multi-result call spread into a variadic or into repeated `any` parameters converts each result and is
// evaluated once.
@(test)
tuple_spread_boxes_results_and_evaluates_the_call_once :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "tuple_spread_variadic", 7)
}
