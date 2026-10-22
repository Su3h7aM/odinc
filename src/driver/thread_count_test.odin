package driver

import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
thread_count_keeps_native_image_byte_identical :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "section_20", "main.odin"}, context.temp_allocator)
	single_log: strings.Builder
	defer strings.builder_destroy(&single_log)
	single, single_err := build_file(odin_root, main_path, strings.to_writer(&single_log), context.allocator, 1)
	if !testing.expectf(t, single_err == nil, "single-threaded build failed: %v\n%s", single_err, strings.to_string(single_log)) { return }
	defer delete(single)
	many_log: strings.Builder
	defer strings.builder_destroy(&many_log)
	many, many_err := build_file(odin_root, main_path, strings.to_writer(&many_log), context.allocator, 8)
	if !testing.expectf(t, many_err == nil, "multi-threaded build failed: %v\n%s", many_err, strings.to_string(many_log)) { return }
	defer delete(many)
	testing.expect(t, slice.equal(single, many))
}
