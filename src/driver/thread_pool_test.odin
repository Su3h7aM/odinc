package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
thread_pool_finishes_with_deferred_guards :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "thread_pool", "main.odin"}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, err := build_file(odin_root, main_path, strings.to_writer(&build_log), context.allocator)
	if !testing.expectf(t, err == nil, "pool fixture must build: %v", strings.to_string(build_log)) { return }
	defer delete(image)
	directory, directory_err := os.make_directory_temp("", "driver-pool-*", context.temp_allocator)
	if !testing.expect(t, directory_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	path, _ := filepath.join({directory, "thread_pool"}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil, "pool executable must be written") { return }
	for _ in 0 ..< 10 {
		output_path, _ := filepath.join({directory, "pool.out"}, context.temp_allocator)
		devnull, devnull_err := os.open("/dev/null", {.Write})
		if !testing.expect(t, devnull_err == nil, "devnull must open") { return }
		state, output, open_err, process_err, wait_err, output_err := run_raw_data_child(path, output_path, devnull)
		_ = os.close(devnull)
		if !testing.expect(t, open_err == nil && process_err == nil && output_err == nil, "pool process must run with readable output") { return }
		if !testing.expectf(t, wait_err == nil && state.exit_code == 0, "pool process exited %d: %v", state.exit_code, wait_err) { return }
		if !testing.expect(t, len(output) == 0, "pool fixture must not print") { return }
	}
}
