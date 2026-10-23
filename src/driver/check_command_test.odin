package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
check_command_checks_without_building :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	for row in ([]struct {
			source:         string,
			no_entry_point: bool,
			error:          Driver_Error,
			diagnostic:     string,
		}{{"package main\nmain :: proc() {}\n", false, .None, ""}, {"package library\nvalue :: 1\n", false, .Check_Failed, "Undefined entry point procedure 'main'"}, {"package library\n#assert(ODIN_NO_ENTRY_POINT)\nvalue :: 1\n", true, .None, ""}, {"package main\nmain :: proc() { value: int = \"bad\"; _ = value }\n", false, .Check_Failed, "Conversion"}, {"package main\nmain :: proc() { value := }\n", false, .Parse_Failed, "parse failed"}, {"package main\nmain :: proc(value: int) {}\n", false, .Check_Failed, "Procedure type of 'main' was expected to be 'proc()'"}, {"package main\nmain :: 42\n", false, .Check_Failed, "'main' is reserved as the entry point procedure"}, {"package main\nmain :: 42\n", true, .Check_Failed, "'main' is reserved as the entry point procedure"}, {"package main\nmain :: proc \"contextless\" () {}\n", true, .None, ""}}) {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)row.source), nil) { return }
		log := strings.builder_make()
		error := check_file(root, main_path, strings.to_writer(&log), context.allocator, row.no_entry_point, nil, nil)
		testing.expect_value(t, error, row.error)
		if row.diagnostic == "" {
			testing.expect_value(t, strings.to_string(log), "")
		} else {
			testing.expect(t, strings.contains(strings.to_string(log), row.diagnostic), strings.to_string(log))
		}
		strings.builder_destroy(&log)
	}
}

@(test)
check_directory_keeps_vet_semicolon_diagnostics :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-vet-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)string("package main\nmain :: proc() { _ = 1; }\n")), nil) { return }
	for enabled in ([2]bool{false, true}) {
		log := strings.builder_make()
		defer strings.builder_destroy(&log)
		error := check_file(root, directory, strings.to_writer(&log), context.allocator, false, nil, nil, parse_options = {vet_semicolon = enabled})
		testing.expect_value(t, error, Driver_Error.Parse_Failed if enabled else Driver_Error.None)
		if enabled {
			testing.expect(t, strings.contains(strings.to_string(log), "Syntax Error: Found unneeded semicolon"), strings.to_string(log))
		} else {
			testing.expect_value(t, strings.to_string(log), "")
		}
	}
}
