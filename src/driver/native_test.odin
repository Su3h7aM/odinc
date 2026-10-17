package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
native_sections_exit_with_interpreter_results :: proc(t: ^testing.T) {
	expected := [?]struct {
		section: string,
		code:    int,
	} {
		{"section_20", 5},
		{"section_21", 127},
		{"section_22", 71},
		{"section_23", 200},
		{"section_24", 122},
		{"section_25", 37},
		{"section_26", 47},
		{"section_28", 128},
	}
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_err := os.make_directory_temp("", "driver-native-*", context.temp_allocator)
	testing.expect(t, directory_err == nil, "temporary directory must be created")
	defer os.remove_all(directory)
	for entry in expected {
		main_path, _ := filepath.join({#directory, "testdata", entry.section, "main.odin"}, context.temp_allocator)
		image, err := build_file(odin_root, main_path, {}, context.allocator)
		if !testing.expectf(t, err == nil, "%s: %v", entry.section, err) { continue }
		defer delete(image)
		path, _ := filepath.join({directory, entry.section}, context.temp_allocator)
		permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
		if !testing.expect(t, os.write_entire_file(path, image, permissions) == nil, "executable must be written") { continue }
		process, process_err := os.process_start(os.Process_Desc{command = []string{path}})
		if !testing.expect(t, process_err == nil, "process must start") { continue }
		state, wait_err := os.process_wait(process)
		testing.expect(t, wait_err == nil && state.exit_code == entry.code, entry.section)
	}
}
