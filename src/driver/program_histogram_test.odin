package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
program_histogram_reports_checker_errors :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "histogram_program", "main.odin"}, context.temp_allocator)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	err := program_histogram(odin_root, main_path, context.allocator, strings.to_writer(&builder))
	testing.expectf(t, err == .None, "%v", err)
	output := strings.to_string(builder)
	testing.expectf(t, strings.contains(output, "1 expr Undeclared_Name missing_name\n"), "%s", output)
	testing.expectf(t, strings.contains(output, "1 expr Conversion Basic_Lit Not_Assignable\n"), "%s", output)
	testing.expectf(t, strings.contains(output, "1 import missing:package\n"), "%s", output)
	testing.expectf(t, strings.contains(output, "total "), "%s", output)
}

@(test)
program_histogram_reports_load_failures :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-histogram-*", context.temp_allocator)
	if !testing.expect(t, directory_error == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	source := "package main\n\nmain :: proc() {\n\tvalue :=\n}\n"
	if !testing.expect(t, os.write_entire_file(main_path, transmute([]byte)source) == nil, "invalid source must be written") {
		return
	}
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	err := program_histogram(odin_root, main_path, context.allocator, strings.to_writer(&builder))
	output := strings.to_string(builder)
	testing.expectf(t, err == .Parse_Failed, "%v", err)
	testing.expectf(t, strings.contains(output, "load parse"), "%s", output)
	testing.expectf(t, strings.contains(output, "1 load parse\ntotal 1\n"), "%s", output)
}
