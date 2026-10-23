package driver

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "oc:types"

Command_Arguments :: struct {
	path, output:                                                      string,
	options:                                                           Test_Options,
	collections:                                                       [dynamic]Collection,
	run_arguments:                                                     []string,
	keep_executable, test_mode, run, check_only, no_entry_point, help: bool,
}

@(private = "file")
Command_Flags :: struct {
	path:                      string `args:"pos=0"`,
	output:                    string,
	collection:                [dynamic]string,
	define:                    [dynamic]string,
	keep_executable:           bool,
	all_packages:              bool,
	thread_count:              int,
	mcpu:                      string,
	opt:                       string,
	sanitize:                  string,
	ignore_unused_defineables: bool,
	lifetime_markers:          bool,
	show_timings:              bool,
	disallow_do:               bool,
}

@(private = "file")
Check_Command_Flags :: struct {
	path:                      string `args:"pos=0"`,
	collection:                [dynamic]string,
	define:                    [dynamic]string,
	no_entry_point:            bool,
	ignore_unused_defineables: bool,
	lifetime_markers:          bool,
	show_timings:              bool,
	disallow_do:               bool,
}

@(private = "file")
parse_command_flag_model :: proc(model: ^$T, args: []string, allocator: runtime.Allocator) -> (help: bool, error: string) {
	if parse_error := flags.parse(model, args, .Unix, allocator = allocator); parse_error != nil {
		switch value in parse_error {
		case flags.Help_Request:
			return true, ""
		case flags.Parse_Error:
			return false, value.message
		case flags.Validation_Error:
			return false, value.message
		case flags.Open_File_Error:
			return false, "Cannot parse command arguments"
		}
	}
	return
}

parse_command_arguments :: proc(name: string, args: []string, allocator := context.allocator) -> (command: Command_Arguments, error: string) {
	args := args
	command.options.defines = make(map[string]string, allocator)
	command.collections = make([dynamic]Collection, allocator)
	command.check_only = name == "check"
	command.test_mode = name == "test"
	command.run = name == "test" || name == "run"
	for argument, index in args {
		if argument == "--" {
			if command.run { command.run_arguments = args[index + 1:] }
			args = args[:index]
			break
		}
	}
	for argument in args {
		if strings.has_prefix(argument, "--") && strings.contains(argument, "=") {
			flag, _, _ := strings.partition(argument, "=")
			return command, fmt.tprintf("use `%s value`, not `%s`", flag, argument)
		}
	}
	model := Command_Flags {
		thread_count = max(os.get_processor_core_count(), 1),
		mcpu         = "x86_64_v1",
	}
	defer delete(model.collection)
	defer delete(model.define)
	if command.check_only {
		check_flags: Check_Command_Flags
		command.help, error = parse_command_flag_model(&check_flags, args, allocator)
		model.path = check_flags.path
		model.collection = check_flags.collection
		model.define = check_flags.define
		command.no_entry_point = check_flags.no_entry_point
		model.disallow_do = check_flags.disallow_do
	} else {
		command.help, error = parse_command_flag_model(&model, args, allocator)
	}
	if command.help || error != "" { return }

	command.path = model.path
	command.output = model.output
	command.keep_executable = model.keep_executable
	command.options.all_packages = model.all_packages
	command.options.thread_count = model.thread_count
	command.options.disallow_do = model.disallow_do
	if command.path == "" { return command, fmt.tprintf("usage: odinc %s <file-or-directory> [options] [-- arguments]", name) }
	if model.sanitize != "" { return command, "odinc test: sanitizers are not supported" }
	if model.thread_count < 1 { return command, "--thread-count expects a positive integer" }
	level, valid := types.parse_x86_level(model.mcpu)
	if !valid { return command, "--mcpu expects one of: x86_64_v1, x86_64_v2, x86_64_v3, x86_64_v4" }
	command.options.microarch = level
	if model.opt != "" {
		if model.opt != "speed" { return command, "--opt expects speed" }
		command.options.optimization_mode = .Speed
	}
	for value in model.collection {
		collection, collection_valid := collection_from_value(value)
		if !collection_valid { return command, "--collection expects name=path" }
		if _, allocation_error := append(&command.collections, collection); allocation_error != nil { return command, "Allocation failed" }
	}
	for value in model.define {
		if parse_define_argument(&command.options.defines, value) != .None { return command, define_argument_error_message(value) }
	}
	return
}

validate_command_input :: proc(command: ^Command_Arguments, root: string, allocator := context.allocator) -> string {
	if strings.contains(command.path, ":") {
		table: Collection_Table
		if collection_table_init(&table, root, allocator) != .None { return "Cannot initialize collections" }
		defer collection_table_destroy(&table)
		for collection in command.collections {
			if collection_add(&table, collection.name, collection.path) != .None { return "Invalid collection" }
		}
		collection_table_freeze(&table)
		input := command.path
		for prefix in ([]string{"runtime", "intrinsics", "builtin"}) {
			if strings.has_prefix(input, fmt.tprintf("core:%s", prefix)) { input = fmt.tprintf("base:%s", input[5:]); break }
		}
		resolved, error := resolve_collection_import(&table, input, ".", allocator)
		if error == .None { command.path = resolved }
	}
	info, stat_error := os.stat(command.path, allocator)
	if stat_error != nil { return fmt.tprintf("The input '%s' could not be found or accessed: %v", command.path, stat_error) }
	defer os.file_info_delete(info, allocator)
	if info.type == .Directory { return "" }
	if info.type != .Regular || !strings.has_suffix(command.path, ".odin") {
		return fmt.tprintf("Expected either a directory or a regular .odin file, got '%s'", command.path)
	}
	return ""
}

// Follows init_build_paths in Odin/src/build_settings.cpp; the result is allocator-owned.
default_output_path :: proc(input: string, allocator := context.allocator) -> (output: string, error: string) {
	absolute, path_error := filepath.abs(input, allocator)
	if path_error != nil { return "", "Cannot resolve input path" }
	defer delete(absolute, allocator)
	directory := absolute
	if !os.is_dir(absolute) { directory = filepath.dir(absolute) }
	collision := os.is_dir(filepath.base(directory))
	name := strings.trim_right(input, "/\\")
	if input == "." || input == "/" { name = filepath.base(directory) }
	if !os.is_dir(input) && strings.has_suffix(name, ".odin") {
		name = name[:len(name) - len(".odin")]
		collision = collision || os.is_dir(name)
	}
	name = strings.trim_space(filepath.base(name))
	if name == "" || name == "/" { return "", "The output name is created from the last path element. Use --output to set it." }
	extension := ""
	when ODIN_OS == .Windows { extension = ".exe" } else { if collision { extension = ".bin" } }
	result, allocation_error := strings.concatenate({name, extension}, allocator)
	if allocation_error != nil { return "", "Allocation failed" }
	return result, ""
}
