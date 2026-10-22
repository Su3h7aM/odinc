#+build !linux
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

run_executable :: proc(executable: string, arguments: []string) -> int {
	absolute, path_error := filepath.abs(executable)
	if path_error != nil { fmt.eprintln("Cannot resolve executable path"); return 1 }
	defer delete(absolute)
	command := make([]string, len(arguments) + 1)
	defer delete(command)
	command[0] = absolute
	copy(command[1:], arguments)
	process, start_error := os.process_start(os.Process_Desc{command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if start_error != nil { fmt.eprintfln("Could not spawn subprocess: %v", start_error); return -1 }
	state, wait_error := os.process_wait(process)
	if wait_error != nil { fmt.eprintfln("Could not wait on subprocess: %v", wait_error); return -1 }
	return state.exit_code
}
