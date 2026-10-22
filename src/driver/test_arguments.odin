package driver

import "core:strconv"
import "core:strings"

Test_Command :: struct {
	path, output: string,
	options:      Test_Options,
	collections:  [dynamic]Collection,
}

parse_test_arguments :: proc(args: []string, allocator := context.allocator) -> (command: Test_Command, error: string) {
	command.options.defines = make(map[string]string, allocator)
	command.collections = make([dynamic]Collection, allocator)
	for argument in args {
		switch {
		case argument == "-file", argument == "-vet", argument == "-strict-style":
		case argument == "-all-packages":
			command.options.all_packages = true
		case argument == "-o:speed":
			command.options.optimization_mode = .Speed
		case strings.has_prefix(argument, "-sanitize:"):
			return command, "odinc test: sanitizers are not supported"
		case strings.has_prefix(argument, "-define:"):
			if parse_define_argument(&command.options.defines, argument) != .None { return command, "expected -define:NAME=value" }
		case strings.has_prefix(argument, "-collection:"):
			value := argument[len("-collection:"):]
			separator := strings.index(value, "=")
			if separator <= 0 || separator == len(value) - 1 { return command, "expected -collection:name=path" }
			if _, allocation_error := append(&command.collections, Collection{value[:separator], value[separator + 1:]});
			   allocation_error != nil { return command, "odinc test: allocation failed" }
		case strings.has_prefix(argument, "-out:"):
			command.output = argument[len("-out:"):]
			if command.output == "" { return command, "odinc test: output path is empty" }
		case strings.has_prefix(argument, "-thread-count:"):
			count, parsed := strconv.parse_int(argument[len("-thread-count:"):])
			if !parsed || count < 1 { return command, "odinc test: expected -thread-count:<positive integer>" }
			command.options.thread_count = count
		case strings.has_prefix(argument, "-"):
			return command, "odinc test: unsupported option"
		case:
			if command.path != "" { return command, "odinc test: expected one file or directory" }
			command.path = argument
		}
	}
	if command.path == "" { return command, "usage: odinc test <file-or-dir> [options]" }
	if command.output == "" { command.output = "odinc_test" }
	return
}
