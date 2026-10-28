package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

main :: proc() {
	if len(os.args) < 3 {
		os.exit(2)
	}

	rss_path := os.args[1]
	n := len(os.args) - 2
	argv := make([]cstring, n + 1)
	for i in 0 ..< n {
		argv[i] = strings.clone_to_cstring(os.args[i + 2])
	}

	env_list, env_err := os.environ(context.allocator)
	if env_err != nil {
		os.exit(1)
	}
	envp := make([]cstring, len(env_list) + 1)
	for entry, i in env_list {
		envp[i] = strings.clone_to_cstring(entry)
	}

	pid, ferr := linux.fork()
	if ferr != .NONE {
		os.exit(1)
	}
	if pid == linux.Pid(0) {
		linux.execve(argv[0], raw_data(argv), raw_data(envp))
		linux.exit(127)
	}

	status: u32
	rusage: linux.RUsage
	_, werr := linux.wait4(pid, &status, {}, &rusage)
	if werr != .NONE {
		os.exit(1)
	}

	buf: [32]byte
	text := strconv.write_int(buf[:], i64(rusage.maxrss_word), 10)
	if os.write_entire_file(rss_path, text) != nil {
		os.exit(1)
	}

	if status & 0x7f == 0 {
		os.exit(int((status >> 8) & 0xff))
	}
	os.exit(128 + int(status & 0x7f))
}
