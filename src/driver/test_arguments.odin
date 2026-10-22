package driver

import "core:fmt"
import "core:strconv"

Test_Command :: struct {
	path, output: string,
	options:      Test_Options,
	collections:  [dynamic]Collection,
}

parse_test_arguments :: proc(args: []string, allocator := context.allocator) -> (command: Test_Command, error: string) {
	command.options.defines = make(map[string]string, allocator)
	command.collections = make([dynamic]Collection, allocator)
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		if !argument_is_flag(argument) {
			if command.path != "" { return command, "odinc test: expected one file or directory" }
			command.path = argument
			continue
		}
		flag, recognized := split_long_flag(argument)
		if !recognized { return command, "odinc test: unsupported option" }
		switch flag.name {
		case "file", "vet", "strict-style":
			if flag.has_value { return command, fmt.tprintf("odinc test: --%s takes no value", flag.name) }
		case "all-packages":
			if flag.has_value { return command, fmt.tprintf("odinc test: --%s takes no value", flag.name) }
			command.options.all_packages = true
		case "opt":
			value, ok := take_flag_value(args, &index, flag)
			if !ok || value != "speed" { return command, "odinc test: --opt expects speed" }
			command.options.optimization_mode = .Speed
		case "sanitize":
			return command, "odinc test: sanitizers are not supported"
		case "define":
			value, ok := take_flag_value(args, &index, flag)
			if !ok || parse_define_argument(&command.options.defines, value) != .None {
				return command, "odinc test: expected --define=NAME=value"
			}
		case "collection":
			value, ok := take_flag_value(args, &index, flag)
			if !ok { return command, "odinc test: expected --collection=name=path" }
			collection, valid := collection_from_value(value)
			if !valid { return command, "odinc test: expected --collection=name=path" }
			if _, allocation_error := append(&command.collections, collection); allocation_error != nil {
				return command, "odinc test: allocation failed"
			}
		case "out":
			value, ok := take_flag_value(args, &index, flag)
			if !ok { return command, "odinc test: --out expects a path" }
			command.output = value
		case "thread-count":
			value, ok := take_flag_value(args, &index, flag)
			count, parsed := strconv.parse_int(value)
			if !ok || !parsed || count < 1 { return command, "odinc test: expected --thread-count=N with a positive integer" }
			command.options.thread_count = count
		case:
			return command, "odinc test: unsupported option"
		}
	}
	if command.path == "" { return command, "usage: odinc test <file-or-dir> [options]" }
	if command.output == "" { command.output = "odinc_test" }
	return
}
