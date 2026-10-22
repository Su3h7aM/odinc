#+build linux
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

run_executable :: proc(executable: string, arguments: []string) -> int {
	absolute, path_error := filepath.abs(executable)
	if path_error != nil { fmt.eprintln("Cannot resolve executable path"); return 1 }
	defer delete(absolute)
	executable_path := strings.clone_to_cstring(absolute)
	defer delete(executable_path)
	argv := make([]cstring, len(arguments) + 2)
	defer delete(argv)
	for index in 0 ..< len(argv) - 1 {
		value := executable
		if index > 0 { value = arguments[index - 1] }
		argv[index] = strings.clone_to_cstring(value)
	}
	defer for value in argv { if value != nil { delete(value) } }
	environment, environment_error := os.environ(context.allocator)
	if environment_error != nil { fmt.eprintfln("Cannot read environment: %v", environment_error); return 1 }
	defer { for value in environment { delete(value) }; delete(environment) }
	envp := make([]cstring, len(environment) + 1)
	defer delete(envp)
	for value, index in environment { envp[index] = strings.clone_to_cstring(value) }
	defer for value in envp { if value != nil { delete(value) } }
	pid, fork_error := linux.fork()
	if fork_error != .NONE { fmt.eprintfln("Could not spawn subprocess: %v", fork_error); return -1 }
	if pid == 0 {
		linux.execve(executable_path, raw_data(argv), raw_data(envp))
		linux.exit_group(127)
	}
	return wait_for_executable(pid)
}

wait_for_executable :: proc(pid: linux.Pid) -> int {
	status: u32
	for {
		_, error := linux.wait4(pid, &status, {.WUNTRACED}, nil)
		if error == .EINTR { continue }
		if error != .NONE { fmt.eprintfln("Could not wait on subprocess: %v", error); return -1 }
		if linux.WIFEXITED(status) { return int(linux.WEXITSTATUS(status)) }
		if linux.WIFSIGNALED(status) {
			signal := linux.Signal(linux.WTERMSIG(status))
			limit: linux.RLimit
			linux.setrlimit(.CORE, &limit)
			action := linux.Sig_Action {
				special = .SIG_DFL,
			}
			if signal != .SIGKILL {
				if action_error := linux.rt_sigaction(signal, &action, nil); action_error != .NONE { return -1 }
			}
			if signal_error := linux.kill(linux.getpid(), signal); signal_error != .NONE { return -1 }
			return -1
		}
		if linux.WIFSTOPPED(status) { return -1 }
	}
}
