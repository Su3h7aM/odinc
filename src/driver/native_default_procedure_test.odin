package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
native_named_procedure_defaults_keep_declaring_bindings :: proc(t: ^testing.T) {
	source := `package main
Callback :: #type proc(value: int) -> int
first :: proc(value: int) -> int { return value + 1 }
second :: proc(value: int) -> int { return value + 2 }
current := first
named: Callback = first
invoke :: proc(callback: Callback = first) -> int { return callback(3) }
mutable :: proc(callback: Callback = current) -> int { return callback(3) }
unchanged :: proc(callback: Callback = named) -> int { return callback(3) }
nullable :: proc(callback: Callback = nil) -> bool { return callback == nil }
literal :: proc(callback: Callback = proc(value: int) -> int { return value + 9 }) -> int { return callback(3) }
main :: proc() {
	first := 99
	assert(first == 99 && invoke() == 4)
	assert(mutable() == 4 && unchanged() == 4)
	current = second
	named = second
	assert(mutable() == 5 && unchanged() == 5)
	assert(nullable() && !nullable(second))
	assert(literal() == 12)
	assert(invoke(second) == 5)
}
`
	directory, directory_error := os.make_directory_temp("", "driver-default-procedure-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	source_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(source_path, transmute([]byte)source), nil) { return }
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, build_error := build_file(odin_root, source_path, strings.to_writer(&build_log), context.allocator, 1)
	if !testing.expectf(t, build_error == nil, "%v: %s", build_error, strings.to_string(build_log)) { return }
	defer delete(image)
	path, _ := filepath.join({directory, "defaults"}, context.temp_allocator)
	if !testing.expect_value(t, write_executable(path, image), nil) { return }
	output_path, _ := filepath.join({directory, "output"}, context.temp_allocator)
	devnull, open_error := os.open("/dev/null", {.Write})
	if !testing.expect_value(t, open_error, nil) { return }
	defer os.close(devnull)
	state, output, output_open_error, process_error, wait_error, output_error := run_raw_data_child(path, output_path, devnull)
	testing.expect(t, output_open_error == nil && process_error == nil && wait_error == nil && output_error == nil)
	testing.expectf(t, state.exit_code == 0, "default procedure fixture exited %d", state.exit_code)
	testing.expect_value(t, len(output), 0)
}
