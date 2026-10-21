package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Byte-identical to the official compiler's output for the same fixture,
// verified by running both during development.
soa_access_golden :: `4
1 2 3
1 2 3
100 12 13
100 12 13
21 22 23
21 22 23
31 32 33
31 32 33
21 22 23
true
2
100 23
192
50 10
2 11
3 12
4 60
12
[70, 60]
4 4
2 2 5
48
`

soa_access_build_and_run :: proc(t: ^testing.T, name: string, capture_stdout: bool) -> (state: os.Process_State, output: []byte, ok: bool) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", name, "main.odin"}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, err := build_file(odin_root, main_path, strings.to_writer(&build_log), context.allocator)
	if !testing.expectf(t, err == nil, "%s fixture must build: %v\n%s", name, err, strings.to_string(build_log)) { return {}, nil, false }
	defer delete(image)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	path, _ := filepath.join({directory, name}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil, "executable must be written") { return {}, nil, false }
	devnull, devnull_err := os.open("/dev/null", {.Write})
	if !testing.expect(t, devnull_err == nil, "devnull must open") { return {}, nil, false }
	defer _ = os.close(devnull)
	stdout: ^os.File
	output_path := ""
	if capture_stdout {
		output_path, _ = filepath.join({directory, "soa_access.stdout"}, context.temp_allocator)
		open_err: os.Error
		stdout, open_err = os.open(output_path, {.Write, .Create, .Trunc})
		if !testing.expect(t, open_err == nil, "stdout file must open") { return {}, nil, false }
	} else {
		stdout = devnull
	}
	process, process_err := start_process(os.Process_Desc{command = []string{path}, stdout = stdout, stderr = devnull})
	if !testing.expect(t, process_err == nil, "process must start") {
		if capture_stdout { _ = os.close(stdout) }
		return {}, nil, false
	}
	wait_state, wait_err := os.process_wait(process)
	if !testing.expect(t, wait_err == nil, "process must finish") {
		if capture_stdout { _ = os.close(stdout) }
		return {}, nil, false
	}
	if capture_stdout {
		_ = os.close(stdout)
		read_output, output_err := os.read_entire_file_from_path(output_path, context.temp_allocator)
		if !testing.expect(t, output_err == nil, "stdout must be readable") { return {}, nil, false }
		return wait_state, read_output, true
	}
	return wait_state, nil, true
}

@(test)
soa_access_values_match_official :: proc(t: ^testing.T) {
	state, output, ok := soa_access_build_and_run(t, "soa_access", true)
	if !ok { return }
	testing.expectf(t, state.exit_code == 0, "soa_access exited %d, expected 0", state.exit_code)
	testing.expectf(t, string(output) == soa_access_golden, "soa_access output must match the official compiler:\n%s", string(output))
}

@(test)
soa_access_out_of_range_traps :: proc(t: ^testing.T) {
	state, _, ok := soa_access_build_and_run(t, "soa_access_oob", false)
	if !ok { return }
	// A bounds-check trap kills the process with SIGILL; the wait status
	// reports the signal rather than a shell-style 128+signal code.
	testing.expectf(t, state.exit_code != 0, "soa_access_oob exited %d, expected a bounds-check trap", state.exit_code)
}
