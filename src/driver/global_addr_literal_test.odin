package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// A composite literal under `&` inside a package-level initializer names storage that must outlive startup. The
// program reads both addresses back after clobbering the startup frame, writes through them, and rechecks the values
// from `@(init)` and `@(fini)`; any dangling slot fails the exit code.
@(test)
nested_addr_literals_survive_startup :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "nested_addr_literal", 0)
}

// A two-valued call has no single type, so using one as a condition is a check-stage rejection, never a crash.
@(test)
tuple_condition_is_rejected :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "tuple_condition_reject", "main.odin"}, context.temp_allocator)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	image, err := build_file(odin_root, main_path, strings.to_writer(&builder), context.allocator, 1)
	testing.expect_value(t, err, Build_Error(Driver_Error.Check_Failed))
	testing.expect_value(t, len(image), 0)
	testing.expect(t, strings.contains(strings.to_string(builder), "Invalid_Operand"), "two-valued condition must be rejected as an invalid operand")
}
