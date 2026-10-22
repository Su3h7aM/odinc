package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
native_scalar_propagation_preserves_effects_and_conversions :: proc(t: ^testing.T) {
	source := `package main
Value :: union { int, f64 }
calls, fallbacks: int
bump :: proc(counter: ^int) -> int { counter^ += 1; return counter^ }
number :: proc(ok: bool) -> (int, bool) { calls += 1; return 7, ok }
text :: proc(ok: bool) -> (string, bool) { calls += 1; return "text", ok }
variant :: proc(ok: bool) -> (Value, bool) { calls += 1; value: Value = 9; return value, ok }
fallback :: proc() -> int { fallbacks += 1; return 13 }
main :: proc() {
	cleanups, successes, evaluations: int
	for {
		defer cleanups += 1
		(bump(&evaluations) == 1) or_break
		successes += 1
	}
	assert(evaluations == 2 && successes == 1 && cleanups == 2)
	cleanups = 0
	sum := 0
	for index := 0; index < 4; index += 1 {
		defer cleanups += 1
		(index != 1) or_continue
		sum += index
	}
	assert(sum == 5 && cleanups == 4)
	visits, nil_successes := 0, 0
	outer: for index := 0; index < 3; index += 1 {
		for {
			defer visits += 1
			status: ^int
			if index == 1 { status = &index }
			status or_continue outer
			nil_successes += 1
			break
		}
	}
	assert(visits == 3 && nil_successes == 2)
	for { true or_continue; break }
	for { false or_break; assert(false) }
	selected: Value = number(true) or_else fallback()
	assert(selected.(int) == 7 && calls == 1 && fallbacks == 0)
	selected = number(false) or_else fallback()
	assert(selected.(int) == 13 && calls == 2 && fallbacks == 1)
	converted := variant(false) or_else fallback()
	assert(converted.(int) == 13 && calls == 3 && fallbacks == 2)
	converted = variant(true) or_else fallback()
	assert(converted.(int) == 9 && calls == 4 && fallbacks == 2)
	name: string
	name = text(false) or_else "fallback"
	assert(len(name) == 8 && calls == 5)
	name = text(true) or_else "fallback"
	assert(len(name) == 4 && calls == 6)
}
`
	directory, directory_error := os.make_directory_temp("", "driver-propagation-*", context.temp_allocator)
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
	path, _ := filepath.join({directory, "propagation"}, context.temp_allocator)
	if !testing.expect_value(t, write_executable(path, image), nil) { return }
	output_path, _ := filepath.join({directory, "output"}, context.temp_allocator)
	devnull, open_error := os.open("/dev/null", {.Write})
	if !testing.expect_value(t, open_error, nil) { return }
	defer os.close(devnull)
	state, output, output_open_error, process_error, wait_error, output_error := run_raw_data_child(path, output_path, devnull)
	testing.expect(t, output_open_error == nil && process_error == nil && wait_error == nil && output_error == nil)
	testing.expectf(t, state.exit_code == 0, "propagation fixture exited %d", state.exit_code)
	testing.expect_value(t, len(output), 0)
}
