package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "oc:driver"
import "oc:types"

USAGE :: "usage: odinc <file-or-dir> --histogram [--collection=name=path] [--mcpu=LEVEL] | odinc <directory|main.odin> --out=<executable> [--collection=name=path] [--define=NAME=value] [--thread-count=N] [--mcpu=LEVEL]"

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "test" {
		os.exit(test_command(os.args[2:]))
	}
	file, out: string
	thread_count := max(os.get_processor_core_count(), 1)
	microarch := types.X86_Level.V1
	collections: [dynamic]driver.Collection
	defer delete(collections)
	defines := make(map[string]string)
	defer delete(defines)
	histogram := false
	args := os.args[1:]
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		if !driver.argument_is_flag(argument) {
			if file != "" {
				fmt.eprintln("odinc: expected one input file or directory")
				os.exit(2)
			}
			file = argument
			continue
		}
		flag, recognized := driver.split_long_flag(argument)
		if !recognized {
			fmt.eprintf("odinc: unknown flag %s\n", argument)
			os.exit(2)
		}
		switch flag.name {
		case "histogram":
			if flag.has_value {
				fmt.eprintln("odinc: --histogram takes no value")
				os.exit(2)
			}
			histogram = true
		case "out":
			value, ok := driver.take_flag_value(args, &index, flag)
			if !ok {
				fmt.eprintln("odinc: --out expects a path")
				os.exit(2)
			}
			out = value
		case "collection":
			value, ok := driver.take_flag_value(args, &index, flag)
			if !ok {
				fmt.eprintln("odinc: --collection expects name=path")
				os.exit(2)
			}
			collection, valid := driver.collection_from_value(value)
			if !valid {
				fmt.eprintln("odinc: --collection expects name=path")
				os.exit(2)
			}
			append(&collections, collection)
		case "define":
			value, ok := driver.take_flag_value(args, &index, flag)
			if !ok {
				fmt.eprintln("odinc: --define expects NAME=value")
				os.exit(2)
			}
			if driver.parse_define_argument(&defines, value) != .None {
				fmt.eprintln(driver.define_argument_error_message(value))
				os.exit(2)
			}
		case "thread-count":
			value, ok := driver.take_flag_value(args, &index, flag)
			count, parsed := strconv.parse_int(value)
			if !ok || !parsed || count < 1 {
				fmt.eprintln("odinc: --thread-count expects a positive integer")
				os.exit(2)
			}
			thread_count = count
		case "mcpu":
			value, ok := driver.take_flag_value(args, &index, flag)
			level, valid := types.parse_x86_level(value)
			if !ok || !valid {
				fmt.eprintln("odinc: --mcpu expects one of: x86_64_v1, x86_64_v2, x86_64_v3, x86_64_v4")
				os.exit(2)
			}
			microarch = level
		case:
			fmt.eprintf("odinc: unknown flag --%s\n", flag.name)
			os.exit(2)
		}
	}
	odin_root, found := os.lookup_env("ODIN_ROOT", context.allocator)
	if !found {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	if histogram {
		if file == "" {
			fmt.eprintln(USAGE)
			os.exit(2)
		}
		file_error: driver.File_Error
		defer driver.file_error_destroy(&file_error, context.allocator)
		if err := driver.program_histogram(odin_root, file, context.allocator, os.to_writer(os.stdout), collections[:], microarch, &file_error); err != nil {
			if file_error.code != nil {
				message := driver.describe_file_error(file_error, context.allocator)
				defer delete(message)
				fmt.eprintfln("histogram failed: %s", message)
			} else {
				fmt.eprintfln("histogram failed: %v", err)
			}
			os.exit(1)
		}
		return
	}
	if file == "" || out == "" {
		fmt.eprintln(USAGE)
		os.exit(2)
	}

	image, err := driver.build_file(odin_root, file, os.to_writer(os.stderr), context.allocator, thread_count, collections[:], defines, microarch)
	if err != nil {
		fmt.eprintln("build failed")
		os.exit(1)
	}
	defer delete(image)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	if write_err := os.write_entire_file(out, image, permissions); write_err != nil {
		message := driver.describe_file_error(driver.File_Error{operation = "cannot write", path = out, code = write_err}, context.allocator)
		fmt.eprintfln("odinc: %s", message)
		delete(message)
		os.exit(1)
	}
}
