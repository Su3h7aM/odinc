package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "oc:driver"

USAGE :: "usage: odinc <file-or-dir> -histogram [-collection:<name>=<path>] | odinc <directory|main.odin> -out:<executable> [-collection:<name>=<path>]"

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "test" {
		os.exit(test_command(os.args[2:]))
	}
	file, out: string
	thread_count := max(os.get_processor_core_count(), 1)
	collections: [dynamic]driver.Collection
	defer delete(collections)
	defines := make(map[string]string)
	defer delete(defines)
	histogram := false
	for arg in os.args[1:] {
		if arg == "-histogram" {
			histogram = true
		} else if strings.has_prefix(arg, "-collection:") {
			value := arg[len("-collection:"):]
			separator := strings.index(value, "=")
			if separator <= 0 || separator == len(value) - 1 {
				fmt.eprintln("expected -collection:name=path")
				os.exit(2)
			}
			append(&collections, driver.Collection{value[:separator], value[separator + 1:]})
		} else if strings.has_prefix(arg, "-out:") {
			out = arg[len("-out:"):]
		} else if strings.has_prefix(arg, "-define:") {
			if driver.parse_define_argument(&defines, arg) != .None {
				fmt.eprintln(driver.define_argument_error_message(arg))
				os.exit(1)
			}
		} else if strings.has_prefix(arg, "-thread-count:") {
			count, parsed := strconv.parse_int(arg[len("-thread-count:"):])
			if !parsed || count < 1 {
				fmt.eprintln("expected -thread-count:<positive integer>")
				os.exit(2)
			}
			thread_count = count
		} else {
			file = arg
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
		if err := driver.program_histogram(odin_root, file, context.allocator, os.to_writer(os.stdout), collections[:]); err != nil {
			fmt.eprintfln("histogram failed: %v", err)
			os.exit(1)
		}
		return
	}
	if file == "" || out == "" {
		fmt.eprintln(USAGE)
		os.exit(2)
	}

	image, err := driver.build_file(odin_root, file, os.to_writer(os.stderr), context.allocator, thread_count, collections[:], defines)
	if err != nil {
		fmt.eprintln("build failed")
		os.exit(1)
	}
	defer delete(image)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	if write_err := os.write_entire_file(out, image, permissions); write_err != nil {
		fmt.eprintfln("write failed: %v", write_err)
		os.exit(1)
	}
}
