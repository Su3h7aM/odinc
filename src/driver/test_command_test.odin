package driver

import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_command_arguments_and_invalid_signature :: proc(t: ^testing.T) {
	command, argument_error := parse_test_arguments(
		[]string{"testdata", "-file", "-all-packages", "-define:COUNT=3", "-collection:custom=somewhere", "-out:tests", "-o:speed", "-vet", "-strict-style"},
	)
	defer delete(command.options.defines)
	defer delete(command.collections)
	testing.expect_value(t, argument_error, "")
	testing.expect(t, command.options.all_packages && command.options.optimization_mode == .Speed)
	testing.expect_value(t, command.options.defines["COUNT"], "3")
	testing.expect(t, len(command.collections) == 1 && command.collections[0] == Collection{"custom", "somewhere"})
	testing.expect(t, command.path == "testdata" && command.output == "tests")
	sanitized, sanitize_error := parse_test_arguments([]string{"testdata", "-sanitize:address"})
	defer delete(sanitized.options.defines)
	defer delete(sanitized.collections)
	testing.expect_value(t, sanitize_error, "odinc test: sanitizers are not supported")
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, _ := filepath.join({#directory, "testdata", "odinc_test_invalid"}, context.temp_allocator)
	log := strings.builder_make()
	defer strings.builder_destroy(&log)
	image, error := build_tests(root, directory, strings.to_writer(&log), context.allocator, {})
	defer delete(image)
	testing.expect(t, error != nil)
	testing.expect(
		t,
		strings.contains(
			strings.to_string(log),
			"invalid_test.odin(4:1) Error: Testing procedures must have a signature type of proc(^testing.T), got proc()",
		),
		strings.to_string(log),
	)
}
