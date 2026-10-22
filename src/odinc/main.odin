package main

import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: odinc <build|run|test|check> <file-or-directory> [options] [-- arguments]"); os.exit(1) }
	switch os.args[1] {
	case "build", "run", "test", "check":
		os.exit(compile_command(os.args[1], os.args[2:]))
	case "--help", "-h":
		fmt.println("usage: odinc <build|run|test|check> <file-or-directory> [--output path] [--keep-executable] [-- arguments]")
	case:
		fmt.eprintfln("Unknown command: '%s'", os.args[1])
		os.exit(1)
	}
}
