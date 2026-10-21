package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
rtti_fields_and_soa_formatting :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "rtti_fields", "main.odin"}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, err := build_file(odin_root, main_path, strings.to_writer(&build_log), context.allocator)
	if !testing.expectf(t, err == nil, "%v\n%s", err, strings.to_string(build_log)) { return }
	defer delete(image)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	path, _ := filepath.join({directory, "rtti_fields"}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil) { return }
	devnull, open_err := os.open("/dev/null", {.Write})
	if !testing.expect(t, open_err == nil) { return }
	defer _ = os.close(devnull)
	output_path, _ := filepath.join({directory, "stdout"}, context.temp_allocator)
	state, output, output_open_err, process_err, wait_err, output_err := run_raw_data_child(path, output_path, devnull)
	if !testing.expect(t, output_open_err == nil && process_err == nil && wait_err == nil && output_err == nil) { return }
	testing.expect_value(t, state.exit_code, 0)
	testing.expect_value(
		t,
		string(output),
		"[\"json:\\\"x\\\"\", \"\"]\n[\"shared:\\\"yes\\\"\", \"shared:\\\"yes\\\"\"]\nfalse\nbit_set[0..=8; u16] bit_set[0..=8]\n[Vector3{x = 1, y = 4, z = 9}, Vector3{x = 2, y = 3, z = 4}]\n[Vector3{x = 1, y = 4, z = 9}, Vector3{x = 2, y = 3, z = 4}]\n[Vector3{x = 1, y = 4, z = 9}, Vector3{x = 2, y = 3, z = 4}]\n",
	)
}
