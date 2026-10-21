package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
deferred_calls_in_control_scopes :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "deferred_cond", "main.odin"}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, err := build_file(odin_root, main_path, strings.to_writer(&build_log), context.allocator)
	if !testing.expectf(t, err == nil, "deferred condition fixture must build: %v", strings.to_string(build_log)) { return }
	defer delete(image)

	directory, directory_err := os.make_directory_temp("", "driver-deferred-cond-*", context.temp_allocator)
	if !testing.expect(t, directory_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	path, _ := filepath.join({directory, "deferred_cond"}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil, "fixture executable must be written") { return }
	output_path, _ := filepath.join({directory, "deferred_cond.out"}, context.temp_allocator)
	devnull, devnull_err := os.open("/dev/null", {.Write})
	if !testing.expect(t, devnull_err == nil, "devnull must open") { return }
	defer os.close(devnull)
	state, output, open_err, process_err, wait_err, output_err := run_raw_data_child(path, output_path, devnull)
	if !testing.expect(t, open_err == nil && process_err == nil && output_err == nil, "fixture must run with readable output") { return }
	if !testing.expectf(t, wait_err == nil && state.exit_code == 0, "fixture exited %d: %v", state.exit_code, wait_err) { return }
	testing.expect(t, len(output) == 0, "fixture must not print")
}
