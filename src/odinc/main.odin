package main

import "core:fmt"
import "core:os"
import "core:strings"
import "oc:driver"

USAGE :: "usage: odinc <main.odin> -out:<executable>"

main :: proc() {
	file, out: string
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-out:") {
			out = arg[len("-out:"):]
		} else {
			file = arg
		}
	}
	odin_root, found := os.lookup_env("ODIN_ROOT", context.allocator)
	if file == "" || out == "" || !found {
		fmt.eprintln(USAGE)
		os.exit(2)
	}

	image, err := driver.build_file(odin_root, file, context.allocator)
	if err != nil {
		fmt.eprintfln("build failed: %v", err)
		os.exit(1)
	}
	defer delete(image)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	if write_err := os.write_entire_file(out, image, permissions); write_err != nil {
		fmt.eprintfln("write failed: %v", write_err)
		os.exit(1)
	}
}
