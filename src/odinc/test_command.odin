package main

import "core:fmt"
import "core:os"
import "oc:driver"

compile_command :: proc(name: string, args: []string) -> int {
	command, argument_error := driver.parse_command_arguments(name, args)
	defer delete(command.options.defines)
	defer delete(command.collections)
	if argument_error != "" { fmt.eprintln(argument_error); return 1 }
	if command.help {
		if command.check_only {
			fmt.println(
				"usage: odinc check <file-or-directory> [--collection/-c name=path] [--define/-d NAME=value] [--no-entry-point] [--disallow-do] [--vet-tabs] [--vet-style] [--strict-style]",
			)
			return 0
		}
		fmt.printfln(
			"usage: odinc %s <file-or-directory> [--output/-o path] [--dynamic-linker path] [--collection/-c name=path] [--define/-d NAME=value] [--keep-executable/-k] [--disallow-do] [--vet-tabs] [--vet-style] [--strict-style] [-- arguments]",
			name,
		)
		return 0
	}
	root, found := os.lookup_env("ODIN_ROOT", context.allocator)
	if !found { fmt.eprintln("odinc: ODIN_ROOT is not set"); return 1 }
	defer delete(root)
	original_path := command.path
	if input_error := driver.validate_command_input(&command, root); input_error != "" { fmt.eprintln(input_error); return 1 }
	defer if command.path != original_path { delete(command.path) }
	if command.check_only {
		if driver.check_file(
			   root,
			   command.path,
			   os.to_writer(os.stderr),
			   context.allocator,
			   command.no_entry_point,
			   command.collections[:],
			   command.options.defines,
			   command.options.parse_options,
			   command.options.check_options,
		   ) !=
		   .None { return 1 }
		return 0
	}

	if command.output == "" {
		output, output_error := driver.default_output_path(command.path)
		if output_error != "" { fmt.eprintln(output_error); return 1 }
		command.output = output
		defer delete(output)
		return build_command_image(root, command)
	}
	return build_command_image(root, command)
}

build_command_image :: proc(root: string, command: driver.Command_Arguments) -> int {
	image: []byte
	error: driver.Build_Error
	if command.test_mode {
		image, error = driver.build_tests(
			root,
			command.path,
			os.to_writer(os.stderr),
			context.allocator,
			command.options,
			command.collections[:],
			command.dynamic_linker,
		)
	} else {
		image, error = driver.build_file(
			root,
			command.path,
			os.to_writer(os.stderr),
			context.allocator,
			command.options.thread_count,
			command.collections[:],
			command.options.defines,
			command.options.microarch,
			command.options.parse_options,
			command.dynamic_linker,
			command.options.check_options,
		)
	}
	if error != nil { return 1 }
	defer delete(image)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	if write_error := os.write_entire_file(command.output, image, permissions); write_error != nil {
		message := driver.describe_file_error(driver.File_Error{operation = "cannot write", path = command.output, code = write_error}, context.allocator)
		defer delete(message)
		fmt.eprintfln("odinc: %s", message)
		return 1
	}
	if !command.run { return 0 }
	status := run_executable(command.output, command.run_arguments)
	if status == 0 && !command.keep_executable { os.remove(command.output) }
	return status
}
