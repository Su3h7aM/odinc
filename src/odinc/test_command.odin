package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "oc:driver"

test_command :: proc(args: []string) -> int {
	command, argument_error := driver.parse_test_arguments(args)
	defer delete(command.options.defines)
	defer delete(command.collections)
	if argument_error != "" { fmt.eprintln(argument_error); return 2 }
	root, found := os.lookup_env("ODIN_ROOT", context.allocator)
	if !found { fmt.eprintln("odinc test: ODIN_ROOT is not set"); return 2 }
	defer delete(root)
	image, error := driver.build_tests(root, command.path, os.to_writer(os.stderr), context.allocator, command.options, command.collections[:])
	if error != nil { return 1 }
	defer delete(image)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	if write_error := os.write_entire_file(command.output, image, permissions); write_error != nil {
		fmt.eprintfln("odinc test: write failed: %v", write_error)
		return 1
	}
	absolute, path_error := filepath.abs(command.output)
	if path_error != nil { fmt.eprintln("odinc test: cannot resolve executable path"); return 1 }
	defer delete(absolute)
	process, start_error := os.process_start(os.Process_Desc{command = []string{absolute}, stdout = os.stdout, stderr = os.stderr})
	if start_error != nil { fmt.eprintfln("odinc test: cannot start executable: %v", start_error); return 1 }
	state, wait_error := os.process_wait(process)
	if wait_error != nil { fmt.eprintfln("odinc test: wait failed: %v", wait_error); return 1 }
	return int(state.exit_code)
}
