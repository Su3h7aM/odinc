package driver

import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"

process_lock: sync.Mutex

write_executable :: proc(path: string, image: []byte) -> os.Error {
	sync.mutex_lock(&process_lock)
	defer sync.mutex_unlock(&process_lock)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	return os.write_entire_file(path, image, permissions)
}

start_process :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	sync.mutex_lock(&process_lock)
	defer sync.mutex_unlock(&process_lock)
	return os.process_start(desc)
}

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
		{"section_29", 15},
		{"section_30", 26},
		{"section_31", 5},
		{"section_32", 100},
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
		if !testing.expect(t, write_executable(path, image) == nil, "executable must be written") { continue }
		devnull, devnull_err := os.open("/dev/null", {.Write})
		testing.expect(t, devnull_err == nil, "devnull must open")
		defer _ = os.close(devnull)
		process, process_err := start_process(os.Process_Desc{command = []string{path}, stdout = devnull, stderr = devnull})
		if !testing.expect(t, process_err == nil, "process must start") { continue }
		state, wait_err := os.process_wait(process)
		testing.expect(t, wait_err == nil && state.exit_code == entry.code, entry.section)
	}
}
