package driver

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
	testing.expectf(t, strings.contains(output, "1  expr Undeclared_Name missing_name  first: "), "%s", output)
	testing.expectf(t, strings.contains(output, "histogram_program/main.odin:4:11"), "%s", output)
	testing.expectf(t, strings.contains(output, "1  expr Conversion Basic_Lit Not_Assignable  first: "), "%s", output)
	testing.expectf(t, strings.contains(output, "histogram_program/main.odin:5:17"), "%s", output)
}
