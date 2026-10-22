package driver

import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_command_arguments_and_invalid_signature :: proc(t: ^testing.T) {
	command, argument_error := parse_test_arguments(
		[]string {
			"testdata",
			"--file",
			"--all-packages",
			"--define=COUNT=3",
			"--collection=custom=somewhere",
			"--out=tests",
			"--opt",
			"speed",
			"--vet",
			"--strict-style",
			"--thread-count=4",
		},
	)
	defer delete(command.options.defines)
	defer delete(command.collections)
	testing.expect_value(t, argument_error, "")
	testing.expect(t, command.options.all_packages && command.options.optimization_mode == .Speed)
	testing.expect_value(t, command.options.thread_count, 4)
	testing.expect_value(t, command.options.defines["COUNT"], "3")
	testing.expect(t, len(command.collections) == 1 && command.collections[0] == Collection{"custom", "somewhere"})
	testing.expect(t, command.path == "testdata" && command.output == "tests")
	sanitized, sanitize_error := parse_test_arguments([]string{"testdata", "--sanitize=address"})
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

@(test)
test_command_rejects_bad_arguments :: proc(t: ^testing.T) {
	Rejected :: struct {
		arguments: []string,
		error:     string,
	}
	rejected := [?]Rejected {
		{[]string{"testdata", "--unknown"}, "odinc test: unsupported option"},
		{[]string{"testdata", "--out"}, "odinc test: --out expects a path"},
		{[]string{"testdata", "--out="}, "odinc test: --out expects a path"},
		{[]string{"testdata", "--collection=nowhere"}, "odinc test: expected --collection=name=path"},
		{[]string{"testdata", "--thread-count=0"}, "odinc test: expected --thread-count=N with a positive integer"},
		{[]string{"one", "two"}, "odinc test: expected one file or directory"},
		{[]string{"testdata", "--histogram"}, "odinc test: unsupported option"},
	}
	for row in rejected {
		command, argument_error := parse_test_arguments(row.arguments)
		delete(command.options.defines)
		delete(command.collections)
		testing.expect_value(t, argument_error, row.error)
	}
}

@(test)
test_command_microarch_level :: proc(t: ^testing.T) {
	command, argument_error := parse_test_arguments([]string{"testdata", "--mcpu=x86_64_v3"})
	defer delete(command.options.defines)
	defer delete(command.collections)
	testing.expect_value(t, argument_error, "")
	testing.expect(t, command.options.microarch == .V3)
	spaced, spaced_error := parse_test_arguments([]string{"testdata", "--mcpu", "x86_64_v2"})
	defer delete(spaced.options.defines)
	defer delete(spaced.collections)
	testing.expect_value(t, spaced_error, "")
	testing.expect(t, spaced.options.microarch == .V2)
	defaulted, default_error := parse_test_arguments([]string{"testdata"})
	defer delete(defaulted.options.defines)
	defer delete(defaulted.collections)
	testing.expect_value(t, default_error, "")
	testing.expect(t, defaulted.options.microarch == .V1)
	rejected := [?]string{"--mcpu=x86_64", "--mcpu=", "--mcpu"}
	for flag in rejected {
		invalid, invalid_error := parse_test_arguments([]string{"testdata", flag})
		delete(invalid.options.defines)
		delete(invalid.collections)
		testing.expect_value(t, invalid_error, "odinc test: --mcpu expects one of: x86_64_v1, x86_64_v2, x86_64_v3, x86_64_v4")
	}
}
