package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
native_optional_returns_evaluate_once_and_convert_results :: proc(t: ^testing.T) {
	source := `package main
Count :: union { int }
Flag :: union { bool }
Value :: union { int, f64 }
table: map[int]int
current: Value
requested, map_reads, key_reads, assertion_reads: int
get_map :: proc() -> map[int]int { map_reads += 1; return table }
get_key :: proc() -> int { key_reads += 1; return requested }
get_variant :: proc() -> Value { assertion_reads += 1; return current }
lookup :: proc() -> (Count, Flag) { return (get_map()[get_key()]) }
asserted :: proc() -> (int, bool) { return (get_variant().?) }
asserted_converted :: proc() -> (Count, Flag) { return get_variant().(int) }
boxed :: proc() -> (Value, Flag) { return get_map()[get_key()] }
main :: proc() {
	table = make(map[int]int)
	defer delete(table)
	table[1] = 41
	requested = 1
	value, found := lookup()
	assert(value.(int) == 41 && found.(bool) && map_reads == 1 && key_reads == 1)
	requested = 2
	value, found = lookup()
	assert(value.(int) == 0 && !found.(bool) && map_reads == 2 && key_reads == 2)
	requested = 1
	variant, valid := boxed()
	assert(variant.(int) == 41 && valid.(bool) && map_reads == 3 && key_reads == 3)
	current = 17
	number, ok := asserted()
	assert(number == 17 && ok && assertion_reads == 1)
	value, found = asserted_converted()
	assert(value.(int) == 17 && found.(bool) && assertion_reads == 2)
	current = f64(3)
	number, ok = asserted()
	assert(number == 0 && !ok && assertion_reads == 3)
	status: any
	current = 9
	number, status = get_variant().(int)
	assert(number == 9 && status.(bool) && assertion_reads == 4)
	current = f64(3)
	number, status = get_variant().(int)
	assert(number == 0 && !status.(bool) && assertion_reads == 5)
	number, status = get_map()[get_key()]
	assert(number == 41 && status.(bool) && map_reads == 4 && key_reads == 4)
	requested = 2
	number, status = get_map()[get_key()]
	assert(number == 0 && !status.(bool) && map_reads == 5 && key_reads == 5)
}
`
	directory, directory_error := os.make_directory_temp("", "driver-optional-return-*", context.temp_allocator)
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
	path, _ := filepath.join({directory, "returns"}, context.temp_allocator)
	if !testing.expect_value(t, write_executable(path, image), nil) { return }
	output_path, _ := filepath.join({directory, "output"}, context.temp_allocator)
	devnull, open_error := os.open("/dev/null", {.Write})
	if !testing.expect_value(t, open_error, nil) { return }
	defer os.close(devnull)
	state, output, output_open_error, process_error, wait_error, output_error := run_raw_data_child(path, output_path, devnull)
	testing.expect(t, output_open_error == nil && process_error == nil && wait_error == nil && output_error == nil)
	testing.expectf(t, state.exit_code == 0, "optional return fixture exited %d", state.exit_code)
	testing.expect_value(t, len(output), 0)
}
