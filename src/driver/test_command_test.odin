package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_command_flag_syntax :: proc(t: ^testing.T) {
	for arguments in ([][]string{{"testdata", "--all-packages", "--output", "tests", "--define", "COUNT=3", "--collection", "custom=somewhere", "--keep-executable"}, {"--all-packages", "--output", "tests", "--define", "COUNT=3", "--collection", "custom=somewhere", "--keep-executable", "testdata"}, {"--all-packages", "testdata", "--output=tests", "-d", "COUNT=3", "-c", "custom=somewhere", "-k"}}) {
		command, error := parse_command_arguments("test", arguments)
		defer delete(command.options.defines)
		defer delete(command.collections)
		testing.expect_value(t, error, "")
		testing.expect(t, command.keep_executable && command.options.all_packages)
		testing.expect_value(t, command.path, "testdata")
		testing.expect_value(t, command.output, "tests")
		testing.expect_value(t, command.options.defines["COUNT"], "3")
		testing.expect(t, len(command.collections) == 1 && command.collections[0] == Collection{"custom", "somewhere"})
	}
	command, error := parse_command_arguments("run", []string{"testdata", "--", "a", "--output=b"})
	defer delete(command.options.defines)
	defer delete(command.collections)
	testing.expect_value(t, error, "")
	testing.expect(t, command.run && len(command.run_arguments) == 2 && command.run_arguments[0] == "a" && command.run_arguments[1] == "--output=b")
	build, build_error := parse_command_arguments(
		"build",
		[]string {
			"testdata",
			"--disallow-do",
			"--show-timings",
			"--lifetime-markers",
			"--ignore-unused-defineables",
			"--vet-tabs",
			"--vet-style",
			"--strict-style",
			"--mcpu",
			"x86_64_v2",
		},
	)
	defer delete(build.options.defines)
	defer delete(build.collections)
	testing.expect_value(t, build_error, "")
	testing.expect(
		t,
		build.options.parse_options.disallow_do &&
		build.options.parse_options.vet_tabs &&
		build.options.parse_options.vet_style &&
		build.options.parse_options.strict_style &&
		build.options.microarch == .V2 &&
		!build.test_mode,
	)
}

@(test)
test_command_bad_flags :: proc(t: ^testing.T) {
	for row in ([]struct {
			arguments: []string,
			message:   string,
		}{{{"testdata", "--unknown"}, "Unable to find any flag named `unknown`."}, {{"testdata", "--output"}, "Expected a value for `output` but none was given."}, {{"testdata", "--build-mode", "test"}, "Unable to find any flag named `build-mode`."}, {{"testdata", "-x", "tests"}, "Unable to find any short flag named `x`."}, {{"testdata", "--mcpu", "x86-64"}, "--mcpu expects one of: x86_64_v1, x86_64_v2, x86_64_v3, x86_64_v4"}}) {
		command, error := parse_command_arguments("test", row.arguments)
		delete(command.options.defines)
		delete(command.collections)
		testing.expect_value(t, error, row.message)
	}
}

@(test)
test_command_default_output :: proc(t: ^testing.T) {
	cwd, cwd_error := os.get_working_directory(context.allocator)
	defer delete(cwd)
	testing.expect(t, cwd_error == nil)
	output, error := default_output_path(".")
	defer delete(output)
	testing.expect_value(t, error, "")
	expected := filepath.base(cwd)
	if os.is_dir(expected) { expected = strings.concatenate({expected, ".bin"}, context.temp_allocator) or_else "" }
	testing.expect_value(t, output, expected)
	file_output, file_error := default_output_path("examples/demo/demo.odin")
	defer delete(file_output)
	testing.expect_value(t, file_error, "")
	testing.expect_value(t, file_output, "demo")
	collision_output, collision_error := default_output_path("src")
	defer delete(collision_output)
	testing.expect_value(t, collision_error, "")
	testing.expect_value(t, collision_output, "src.bin")
}

@(test)
test_command_invalid_signature :: proc(t: ^testing.T) {
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
test_command_input_kind :: proc(t: ^testing.T) {
	for path in ([]string{#directory, #file}) {
		command := Command_Arguments {
			path = path,
		}
		testing.expect_value(t, validate_command_input(&command, ""), "")
	}
	invalid, _ := filepath.join({#directory, "testdata", "config_define", "flags"}, context.temp_allocator)
	command := Command_Arguments {
		path = invalid,
	}
	testing.expect(t, strings.contains(validate_command_input(&command, ""), "regular .odin file"))
	command.path = "/__odinc_missing_input__/main.odin"
	testing.expect(t, strings.contains(validate_command_input(&command, ""), "could not be found or accessed"))
	for name in ([]string{"file", "vet"}) {
		arguments := []string{#directory, strings.concatenate({"--", name}, context.temp_allocator) or_else ""}
		parsed, error := parse_command_arguments("build", arguments)
		delete(parsed.options.defines)
		delete(parsed.collections)
		testing.expect(t, strings.contains(error, "Unable to find any flag named"))
	}
}
@(test)
test_check_command_flags :: proc(t: ^testing.T) {
	for arguments in ([][]string{{"source.odin", "--no-entry-point", "--disallow-do", "--collection", "custom=somewhere", "--define", "COUNT=3"}, {"--no-entry-point", "--disallow-do", "--collection", "custom=somewhere", "--define", "COUNT=3", "source.odin"}}) {
		command, error := parse_command_arguments("check", arguments)
		defer delete(command.options.defines)
		defer delete(command.collections)
		testing.expect_value(t, error, "")
		testing.expect(t, command.check_only && command.no_entry_point && !command.run && !command.test_mode)
		testing.expect(t, command.options.parse_options.disallow_do)
		testing.expect_value(t, command.path, "source.odin")
		testing.expect_value(t, command.options.defines["COUNT"], "3")
		testing.expect(t, len(command.collections) == 1 && command.collections[0] == Collection{"custom", "somewhere"})
	}
	for argument in ([]string{"--output", "--keep-executable", "--build-mode", "--histogram", "-C", "-D"}) {
		command, error := parse_command_arguments("check", []string{"source.odin", argument})
		delete(command.options.defines)
		delete(command.collections)
		testing.expect(t, error != "")
	}
}
@(test)
dynamic_linker_command_flag :: proc(t: ^testing.T) {
	for name in ([]string{"build", "run", "test"}) {
		defaults, default_error := parse_command_arguments(name, []string{"source.odin"})
		defer delete(defaults.options.defines)
		defer delete(defaults.collections)
		testing.expect_value(t, default_error, "")
		testing.expect_value(t, defaults.dynamic_linker, "/lib64/ld-linux-x86-64.so.2")
		for arguments in ([][]string{{"source.odin", "--dynamic-linker", "/lib/ld-musl-x86_64.so.1"}, {"--dynamic-linker=/lib/ld-musl-x86_64.so.1", "source.odin"}}) {
			command, error := parse_command_arguments(name, arguments)
			defer delete(command.options.defines)
			defer delete(command.collections)
			testing.expect_value(t, error, "")
			testing.expect_value(t, command.dynamic_linker, "/lib/ld-musl-x86_64.so.1")
			testing.expect_value(t, command.path, "source.odin")
		}
	}
	for arguments in ([][]string{{"source.odin", "--dynamic-linker", "/lib/ld-musl-x86_64.so.1"}, {"source.odin", "--dynamic-linker=/lib/ld-musl-x86_64.so.1"}}) {
		command, error := parse_command_arguments("check", arguments)
		defer delete(command.options.defines)
		defer delete(command.collections)
		testing.expect(t, error != "", "check does not accept linker options")
	}
	for arguments in ([][]string{{"source.odin", "--dynamic-linker"}, {"source.odin", "-I", "/lib/ld-musl-x86_64.so.1"}}) {
		command, error := parse_command_arguments("build", arguments)
		defer delete(command.options.defines)
		defer delete(command.collections)
		testing.expect(t, error != "", "a loader path and the long flag spelling are required")
	}
}

@(test)
vet_options_reach_every_checking_command :: proc(t: ^testing.T) {
	for name in ([]string{"build", "run", "test", "check"}) {
		command, error := parse_command_arguments(
			name,
			[]string {
				"testdata",
				"--vet-using-stmt",
				"--vet-using-param",
				"--vet-semicolon",
				"--vet-unused",
				"--vet-shadowing",
				"--vet-cast",
				"--warnings-as-errors",
			},
		)
		defer delete(command.options.defines)
		defer delete(command.collections)
		testing.expect_value(t, error, "")
		testing.expect(
			t,
			command.options.check_options.vet_using_stmt &&
			command.options.check_options.vet_using_param &&
			command.options.check_options.vet_shadowing &&
			command.options.check_options.vet_cast &&
			command.options.check_options.vet_unused_variables &&
			command.options.check_options.vet_unused_imports &&
			command.options.check_options.warnings_as_errors &&
			command.options.parse_options.vet_semicolon,
		)
	}
}
