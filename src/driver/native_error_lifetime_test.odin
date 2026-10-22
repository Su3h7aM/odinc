package driver

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
native_build_errors_remain_formatable_after_cleanup :: proc(t: ^testing.T) {
	source := `package main
foreign {
	missing_external :: proc "c" () ---
}
main :: proc() {
	missing_external()
}
`
	directory, directory_error := os.make_directory_temp("", "driver-error-lifetime-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	source_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(source_path, transmute([]byte)source), nil) { return }
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, build_error := build_file(odin_root, source_path, strings.to_writer(&build_log), context.allocator, 1)
	if !testing.expect(t, image == nil && build_error != nil) { return }
	defer delete(image)
	if !testing.expect(t, strings.contains(strings.to_string(build_log), "missing_external")) { return }
	#partial switch value in build_error {
	case Link_Failed:
	case:
		testing.expectf(t, false, "expected Link_Failed, got %v", build_error)
		return
	}
	formatted_error: strings.Builder
	defer strings.builder_destroy(&formatted_error)
	fmt.sbprintf(&formatted_error, "%v", build_error)
	testing.expect(t, len(strings.to_string(formatted_error)) > 0)
}
