package driver

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Real OS threads end to end: three workers print three iterations each and
// are joined. Output interleaves run to run, so the test compares the set of
// lines, and runs the binary ten times to catch flakes.
@(test)
thread_start_runs_three_threads_to_completion :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "thread_start", "main.odin"}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, err := build_file(odin_root, main_path, strings.to_writer(&build_log), context.allocator, 1)
	if !testing.expectf(t, err == nil, "thread fixture must build: %v", strings.to_string(build_log)) { return }
	defer delete(image)
	directory, directory_err := os.make_directory_temp("", "driver-thread-*", context.temp_allocator)
	if !testing.expect(t, directory_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	path, _ := filepath.join({directory, "thread_start"}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil, "thread executable must be written") { return }

	expected := make(map[string]bool, 12, context.temp_allocator)
	for index in 0 ..< 3 {
		for iteration in 1 ..= 3 {
			expected[fmt.aprintf("Thread %d iteration %d", index, iteration, allocator = context.temp_allocator)] = false
		}
		expected[fmt.aprintf("Thread %d done", index, allocator = context.temp_allocator)] = false
	}
	for _ in 0 ..< 10 {
		output_path, _ := filepath.join({directory, "thread.out"}, context.temp_allocator)
		devnull, devnull_err := os.open("/dev/null", {.Write})
		if !testing.expect(t, devnull_err == nil, "devnull must open") { return }
		state, output, open_err, process_err, wait_err, output_err := run_raw_data_child(path, output_path, devnull)
		_ = os.close(devnull)
		if !testing.expect(t, open_err == nil, "thread stdout file must open") { return }
		if !testing.expect(t, process_err == nil, "thread process must start") { return }
		if !testing.expectf(t, wait_err == nil && state.exit_code == 0, "thread process exited %d, expected 0: %v", state.exit_code, wait_err) { return }
		if !testing.expect(t, output_err == nil, "thread stdout must be readable") { return }
		seen := make(map[string]bool, 12, context.temp_allocator)
		lines := strings.split_lines(string(output), context.temp_allocator)
		for line in lines {
			if len(line) == 0 { continue }
			if !testing.expectf(t, line in expected, "unexpected thread output line %q", line) { return }
			seen[line] = true
		}
		for line in expected {
			if !testing.expectf(t, line in seen, "missing thread output line %q", line) { return }
		}
	}
}
