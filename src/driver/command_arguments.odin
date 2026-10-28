package driver

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "oc:check"
import "oc:syntax"
import "oc:types"

Command_Arguments :: struct {
	dynamic_linker:                                                    string,
	path, output:                                                      string,
	options:                                                           Test_Options,
	collections:                                                       [dynamic]Collection,
	run_arguments:                                                     []string,
	keep_executable, test_mode, run, check_only, no_entry_point, help: bool,
}

Command_Name :: enum u8 {
	Build,
	Run,
	Test,
	Check,
}

Command_Set :: bit_set[Command_Name;u8]

// Every flag the odinc commands accept. A flag that a command does not use is rejected for that command.
Flag_Id :: enum u8 {
	Help,
	Output,
	Dynamic_Linker,
	Collection,
	Define,
	Keep_Executable,
	All_Packages,
	Thread_Count,
	Mcpu,
	Opt,
	Sanitize,
	Max_Error_Count,
	No_Entry_Point,
	Disallow_Do,
	No_Escape_Analysis,
	No_Atomic_Analysis,
	Vet,
	Vet_Atomic_Access,
	Vet_Tabs,
	Vet_Style,
	Vet_Semicolon,
	Vet_Using_Stmt,
	Vet_Using_Param,
	Vet_Unused,
	Vet_Unused_Variables,
	Vet_Unused_Imports,
	Vet_Shadowing,
	Vet_Cast,
	Vet_Unused_Procedures,
	Vet_Packages,
	Vet_When_Shadowing,
	Vet_Nil_Deref,
	Vet_Uninitialized,
	Warnings_As_Errors,
	Ignore_Warnings,
	Strict_Style,
}

Value_Kind :: enum u8 {
	Switch,
	Text,
	Number,
	List,
}

Flag_Spec :: struct {
	name:        string,
	short:       u8,
	kind:        Value_Kind,
	placeholder: string,
	commands:    Command_Set,
}

ALL_COMMANDS :: Command_Set{.Build, .Run, .Test, .Check}
IMAGE_COMMANDS :: Command_Set{.Build, .Run, .Test}
RUN_COMMANDS :: Command_Set{.Run, .Test}

FLAGS := [Flag_Id]Flag_Spec {
	.Help = {name = "help", short = 'h', commands = ALL_COMMANDS},
	.Output = {name = "output", short = 'o', kind = .Text, placeholder = "path", commands = IMAGE_COMMANDS},
	.Dynamic_Linker = {name = "dynamic-linker", kind = .Text, placeholder = "path", commands = IMAGE_COMMANDS},
	.Collection = {name = "collection", short = 'c', kind = .List, placeholder = "name=path", commands = ALL_COMMANDS},
	.Define = {name = "define", short = 'd', kind = .List, placeholder = "NAME=value", commands = ALL_COMMANDS},
	.Keep_Executable = {name = "keep-executable", short = 'k', commands = RUN_COMMANDS},
	.All_Packages = {name = "all-packages", commands = {.Test}},
	.Thread_Count = {name = "thread-count", kind = .Number, placeholder = "integer", commands = IMAGE_COMMANDS},
	.Mcpu = {name = "mcpu", kind = .Text, placeholder = "level", commands = ALL_COMMANDS},
	.Opt = {name = "opt", kind = .Text, placeholder = "speed", commands = IMAGE_COMMANDS},
	.Sanitize = {name = "sanitize", kind = .Text, placeholder = "flags", commands = IMAGE_COMMANDS},
	.Max_Error_Count = {name = "max-error-count", kind = .Number, placeholder = "integer", commands = ALL_COMMANDS},
	.No_Entry_Point = {name = "no-entry-point", commands = {.Check}},
	.Disallow_Do = {name = "disallow-do", commands = ALL_COMMANDS},
	.No_Escape_Analysis = {name = "no-escape-analysis", commands = ALL_COMMANDS},
	.No_Atomic_Analysis = {name = "no-atomic-analysis", commands = ALL_COMMANDS},
	.Vet = {name = "vet", commands = ALL_COMMANDS},
	.Vet_Atomic_Access = {name = "vet-atomic-access", commands = ALL_COMMANDS},
	.Vet_Tabs = {name = "vet-tabs", commands = ALL_COMMANDS},
	.Vet_Style = {name = "vet-style", commands = ALL_COMMANDS},
	.Vet_Semicolon = {name = "vet-semicolon", commands = ALL_COMMANDS},
	.Vet_Using_Stmt = {name = "vet-using-stmt", commands = ALL_COMMANDS},
	.Vet_Using_Param = {name = "vet-using-param", commands = ALL_COMMANDS},
	.Vet_Unused = {name = "vet-unused", commands = ALL_COMMANDS},
	.Vet_Unused_Variables = {name = "vet-unused-variables", commands = ALL_COMMANDS},
	.Vet_Unused_Imports = {name = "vet-unused-imports", commands = ALL_COMMANDS},
	.Vet_Shadowing = {name = "vet-shadowing", commands = ALL_COMMANDS},
	.Vet_Cast = {name = "vet-cast", commands = ALL_COMMANDS},
	.Vet_Unused_Procedures = {name = "vet-unused-procedures", commands = ALL_COMMANDS},
	.Vet_Packages = {name = "vet-packages", kind = .Text, placeholder = "names", commands = ALL_COMMANDS},
	.Vet_When_Shadowing = {name = "vet-when-shadowing", commands = ALL_COMMANDS},
	.Vet_Nil_Deref = {name = "vet-nil-deref", commands = ALL_COMMANDS},
	.Vet_Uninitialized = {name = "vet-uninitialized", commands = ALL_COMMANDS},
	.Warnings_As_Errors = {name = "warnings-as-errors", commands = ALL_COMMANDS},
	.Ignore_Warnings = {name = "ignore-warnings", commands = ALL_COMMANDS},
	.Strict_Style = {name = "strict-style", commands = ALL_COMMANDS},
}

@(private = "file")
Command_Model :: struct {
	path, output, dynamic_linker, mcpu, opt, sanitize, vet_packages: string,
	collection, define:                                              [dynamic]string,
	thread_count, max_error_count:                                   int,
	switches:                                                        bit_set[Flag_Id],
}

command_from_name :: proc(name: string) -> (command: Command_Name, valid: bool) {
	switch name {
	case "build":
		return .Build, true
	case "run":
		return .Run, true
	case "test":
		return .Test, true
	case "check":
		return .Check, true
	}
	return {}, false
}

// Splits `--name=value`, `--name` or `-x` into a flag of the table; `found` is false for an unknown name.
@(private = "file")
flag_from_argument :: proc(argument: string) -> (id: Flag_Id, value: string, has_value, found: bool) {
	if strings.has_prefix(argument, "--") {
		name := argument[2:]
		if equals := strings.index_byte(name, '='); equals >= 0 {
			value, has_value = name[equals + 1:], true
			name = name[:equals]
		}
		for candidate in Flag_Id {
			if FLAGS[candidate].name == name { return candidate, value, has_value, true }
		}
		return
	}
	if len(argument) != 2 { return }
	for candidate in Flag_Id {
		if FLAGS[candidate].short == argument[1] { return candidate, "", false, true }
	}
	return
}

@(private = "file")
set_flag_value :: proc(model: ^Command_Model, id: Flag_Id, value: string) -> string {
	#partial switch id {
	case .Output:
		model.output = value
	case .Dynamic_Linker:
		model.dynamic_linker = value
	case .Collection:
		append(&model.collection, value)
	case .Define:
		append(&model.define, value)
	case .Thread_Count:
		count, valid := strconv.parse_int(value)
		if !valid { return "--thread-count expects a positive integer" }
		model.thread_count = count
	case .Max_Error_Count:
		count, valid := strconv.parse_int(value)
		if !valid { return "--max-error-count expects an integer" }
		model.max_error_count = count
	case .Mcpu:
		model.mcpu = value
	case .Opt:
		model.opt = value
	case .Sanitize:
		model.sanitize = value
	case .Vet_Packages:
		model.vet_packages = value
	}
	return ""
}

@(private = "file")
parse_flags :: proc(model: ^Command_Model, name: string, command: Command_Name, args: []string) -> string {
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		if !strings.has_prefix(argument, "-") {
			if model.path != "" { return fmt.tprintf("unexpected argument '%s'", argument) }
			model.path = argument
			continue
		}
		id, value, has_value, found := flag_from_argument(argument)
		if !found { return unknown_flag_message(argument) }
		spec := FLAGS[id]
		if command not_in spec.commands { return fmt.tprintf("--%s is not accepted by odinc %s", spec.name, name) }
		if spec.kind == .Switch {
			if has_value { return fmt.tprintf("--%s takes no value", spec.name) }
			if id == .Warnings_As_Errors && .Ignore_Warnings in model.switches { return "--warnings-as-errors cannot be used with --ignore-warnings" }
			if id == .Ignore_Warnings && .Warnings_As_Errors in model.switches { return "--ignore-warnings cannot be used with --warnings-as-errors" }
			model.switches += {id}
			continue
		}
		if !has_value {
			if index + 1 >= len(args) { return fmt.tprintf("Expected a value for `%s` but none was given.", spec.name) }
			index += 1
			value = args[index]
		}
		if error := set_flag_value(model, id, value); error != "" { return error }
	}
	return ""
}

@(private = "file")
unknown_flag_message :: proc(argument: string) -> string {
	if !strings.has_prefix(argument, "--") { return fmt.tprintf("Unable to find any short flag named `%s`.", argument[1:]) }
	name := argument[2:]
	if equals := strings.index_byte(name, '='); equals >= 0 { name = name[:equals] }
	return fmt.tprintf("Unable to find any flag named `%s`.", name)
}

parse_command_arguments :: proc(name: string, args: []string, allocator := context.allocator) -> (command: Command_Arguments, error: string) {
	kind, known := command_from_name(name)
	if !known { return command, fmt.tprintf("unknown command '%s'", name) }
	args := args
	command.options.defines = make(map[string]string, allocator)
	command.collections = make([dynamic]Collection, allocator)
	command.check_only = kind == .Check
	command.test_mode = kind == .Test
	command.run = kind == .Test || kind == .Run
	for argument, index in args {
		if argument == "--" {
			if command.run { command.run_arguments = args[index + 1:] }
			args = args[:index]
			break
		}
	}
	model := Command_Model {
		collection      = make([dynamic]string, allocator),
		define          = make([dynamic]string, allocator),
		max_error_count = 36,
		thread_count    = max(os.get_processor_core_count(), 1),
		mcpu            = "x86_64_v1",
		dynamic_linker  = LINUX_AMD64_DYNAMIC_INTERPRETER,
	}
	defer delete(model.collection)
	defer delete(model.define)
	error = parse_flags(&model, name, kind, args)
	command.help = .Help in model.switches
	if command.help || error != "" { return command, error }
	if model.max_error_count <= 0 { return command, "--max-error-count must be greater than 0" }
	if .No_Atomic_Analysis in model.switches &&
	   .Vet_Atomic_Access in model.switches { return command, "--vet-atomic-access cannot be used with --no-atomic-analysis, as it is part of it" }
	if .No_Escape_Analysis in model.switches &&
	   (.Vet_Nil_Deref in model.switches ||
			   .Vet_Uninitialized in
				   model.switches) { return command, "--vet-nil-deref and --vet-uninitialized cannot be used with --no-escape-analysis, as they are part of it" }
	command.path = model.path
	command.output = model.output
	command.dynamic_linker = model.dynamic_linker
	command.keep_executable = .Keep_Executable in model.switches
	command.no_entry_point = .No_Entry_Point in model.switches
	command.options.all_packages = .All_Packages in model.switches
	command.options.thread_count = model.thread_count
	command.options.max_error_count = model.max_error_count
	vet_packages, vet_packages_error := parse_vet_packages(model.vet_packages, allocator)
	if vet_packages_error != "" { return command, vet_packages_error }
	if .Vet_Unused_Procedures in model.switches && model.vet_packages == "" { return command, "--vet-unused-procedures must be used with --vet-packages" }
	command.options.check_options = check.Check_Options {
		warnings_as_errors = .Warnings_As_Errors in model.switches,
		ignore_warnings    = .Ignore_Warnings in model.switches,
	}
	command.options.parse_options = syntax.Parse_Options {
		disallow_do  = .Disallow_Do in model.switches,
		vet          = vet_flags_from_command(model.switches),
		vet_packages = vet_packages,
		strict_style = .Strict_Style in model.switches,
	}
	if .No_Escape_Analysis in model.switches { command.options.parse_options.no_analysis += {.Escape} }
	if .No_Atomic_Analysis in model.switches { command.options.parse_options.no_analysis += {.Atomic} }
	if command.path == "" { return command, fmt.tprintf("usage: odinc %s <file-or-directory> [options] [-- arguments]", name) }
	if model.sanitize != "" { return command, "odinc test: sanitizers are not supported" }
	if model.thread_count < 1 { return command, "--thread-count expects a positive integer" }
	level, valid := types.parse_x86_level(model.mcpu)
	if !valid { return command, "--mcpu expects one of: x86_64_v1, x86_64_v2, x86_64_v3, x86_64_v4, native" }
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

// The usage text of `name`, listing the flags its command accepts from FLAGS; the result is allocator-owned.
command_usage :: proc(name: string, allocator := context.allocator) -> string {
	command, _ := command_from_name(name)
	builder := strings.builder_make(allocator)
	fmt.sbprintfln(&builder, "usage: odinc %s <file-or-directory> [options] [-- arguments]\n\noptions:", name)
	for id in Flag_Id {
		spec := FLAGS[id]
		if command not_in spec.commands { continue }
		if spec.short != 0 {
			fmt.sbprintf(&builder, "  -%c, --%s", rune(spec.short), spec.name)
		} else {
			fmt.sbprintf(&builder, "      --%s", spec.name)
		}
		if spec.placeholder != "" { fmt.sbprintf(&builder, " %s", spec.placeholder) }
		strings.write_byte(&builder, '\n')
	}
	return strings.to_string(builder)
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

// `--vet` is VetFlag_All of the official build_settings.cpp, which leaves out using-param, style, semicolon and tabs.
@(private = "file")
vet_flags_from_command :: proc(switches: bit_set[Flag_Id]) -> (flags: syntax.Vet_Flags) {
	if .Vet in switches { flags += syntax.VET_ALL }
	if .Vet_Unused in switches { flags += syntax.VET_UNUSED }
	if .Vet_Unused_Variables in switches { flags += {.Unused_Variables} }
	if .Vet_Unused_Imports in switches { flags += {.Unused_Imports} }
	if .Vet_Unused_Procedures in switches { flags += {.Unused_Procedures} }
	if .Vet_Shadowing in switches { flags += {.Shadowing} }
	if .Vet_Using_Stmt in switches { flags += {.Using_Stmt} }
	if .Vet_Using_Param in switches { flags += {.Using_Param} }
	if .Vet_Style in switches { flags += {.Style} }
	if .Vet_Semicolon in switches { flags += {.Semicolon} }
	if .Vet_Cast in switches { flags += {.Cast} }
	if .Vet_Atomic_Access in switches { flags += {.Atomic_Access} }
	if .Vet_Tabs in switches { flags += {.Tabs} }
	if .Vet_When_Shadowing in switches { flags += {.When_Shadowing} }
	if .Vet_Nil_Deref in switches { flags += {.Nil_Deref} }
	if .Vet_Uninitialized in switches { flags += {.Uninitialized} }
	return
}

// A comma separated list of package names, each a valid identifier, as main.cpp BuildFlag_VetPackages reads it.
@(private = "file")
parse_vet_packages :: proc(value: string, allocator: runtime.Allocator) -> (names: []string, error: string) {
	if value == "" { return nil, "" }
	parts, split_error := strings.split(value, ",", allocator)
	if split_error != nil { return nil, "Allocation failed" }
	for &part in parts {
		part = strings.trim_space(part)
		valid := part != "" && !(part[0] >= '0' && part[0] <= '9')
		for char in part { valid &&= char == '_' || char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' || char >= 0x80 }
		if !valid {
			message := fmt.tprintf("--vet-packages '%s' must be a valid identifier", part)
			delete(parts, allocator)
			return nil, message
		}
	}
	return parts, ""
}
