package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oc:check"
import "oc:syntax"

@(test)
check_command_warning_controls_and_anonymous_type_diagnostics :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-warnings-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	source := `package main
S :: struct #field_align(8) { x: int }
main :: proc() {
	x: struct { a: int }
	_ = cast(type_of(x))x
	y: union { int, string }
	_ = cast(type_of(y))y
	e: enum { A, B }
	_ = cast(type_of(e))e
	b: bit_set[0..=3]
	_ = cast(type_of(b))b
	p: proc "contextless" (x: int, args: ..string) -> (a: bool, b: int)
	_ = cast(type_of(p))p
}
`
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
	for row in ([]struct {
			vet:     syntax.Vet_Flags,
			options: check.Check_Options,
			error:   Driver_Error,
			warning: bool,
		}{{{}, {}, .None, true}, {{.Deprecated}, {}, .None, true}, {{}, {warnings_as_errors = true}, .Check_Failed, true}, {{}, {ignore_warnings = true}, .None, false}, {{.Cast}, {ignore_warnings = true}, .Check_Failed, false}}) {
		log := strings.builder_make()
		error := check_file(
			root,
			main_path,
			strings.to_writer(&log),
			context.allocator,
			false,
			nil,
			nil,
			parse_options = {vet = row.vet},
			check_options = row.options,
		)
		testing.expect_value(t, error, row.error)
		text := strings.to_string(log)
		testing.expect_value(t, strings.contains(text, "#field_align has been deprecated in favour of #min_field_align"), row.warning)
		if .Cast in row.vet {
			for spelling in ([]string{"struct {a: int}", "union {int, string}", "enum int {A, B}", "bit_set[0..=3]", "proc \"contextless\" (int, ..string) -> (bool, int)"}) {
				testing.expect(t, strings.contains(text, spelling), text)
			}
		}
		strings.builder_destroy(&log)
	}
	for arguments, index in ([][]string{{".", "--ignore-warnings", "--warnings-as-errors"}, {".", "--warnings-as-errors", "--ignore-warnings"}}) {
		command, error := parse_command_arguments("check", arguments)
		defer delete(command.collections)
		defer delete(command.options.defines)
		expected := "-warnings-as-errors cannot be used with -ignore-warnings" if index == 0 else "-ignore-warnings cannot be used with -warnings-as-errors"
		testing.expect_value(t, error, expected)
	}
}

@(test)
check_command_checks_without_building :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	for row in ([]struct {
			source:         string,
			no_entry_point: bool,
			error:          Driver_Error,
			diagnostic:     string,
		}{{"package main\nmain :: proc() {}\n", false, .None, ""}, {"package library\nvalue :: 1\n", false, .Check_Failed, "Undefined entry point procedure 'main'"}, {"package library\n#assert(ODIN_NO_ENTRY_POINT)\nvalue :: 1\n", true, .None, ""}, {"package main\nmain :: proc() { value: int = \"bad\"; _ = value }\n", false, .Check_Failed, "Conversion"}, {"package main\nmain :: proc() { value := }\n", false, .Parse_Failed, "parse failed"}, {"package main\nmain :: proc(value: int) {}\n", false, .Check_Failed, "Procedure type of 'main' was expected to be 'proc()'"}, {"package main\nmain :: 42\n", false, .Check_Failed, "'main' is reserved as the entry point procedure"}, {"package main\nmain :: 42\n", true, .Check_Failed, "'main' is reserved as the entry point procedure"}, {"package main\nmain :: proc \"contextless\" () {}\n", true, .None, ""}}) {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)row.source), nil) { return }
		log := strings.builder_make()
		error := check_file(root, main_path, strings.to_writer(&log), context.allocator, row.no_entry_point, nil, nil)
		testing.expect_value(t, error, row.error)
		if row.diagnostic == "" {
			testing.expect_value(t, strings.to_string(log), "")
		} else {
			testing.expect(t, strings.contains(strings.to_string(log), row.diagnostic), strings.to_string(log))
		}
		strings.builder_destroy(&log)
	}
}

@(test)
check_directory_keeps_vet_semicolon_diagnostics :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-vet-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)string("package main\nmain :: proc() { _ = 1; }\n")), nil) { return }
	for enabled in ([2]bool{false, true}) {
		log := strings.builder_make()
		defer strings.builder_destroy(&log)
		error := check_file(
			root,
			directory,
			strings.to_writer(&log),
			context.allocator,
			false,
			nil,
			nil,
			parse_options = {vet = {.Semicolon} if enabled else {}},
		)
		testing.expect_value(t, error, Driver_Error.Parse_Failed if enabled else Driver_Error.None)
		if enabled {
			testing.expect(t, strings.contains(strings.to_string(log), "Syntax Error: Found unneeded semicolon"), strings.to_string(log))
		} else {
			testing.expect_value(t, strings.to_string(log), "")
		}
	}
}

@(test)
check_command_reports_when_shadowing_and_deprecated_imports :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-when-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	for row in ([]struct {
			source: string,
			vet:    syntax.Vet_Flags,
			error:  Driver_Error,
			text:   string,
		}{{"package main\nwhen true {\n\tlen :: 1\n}\nmain :: proc() {}\n", {.When_Shadowing}, .Check_Failed, "Declaration of 'len' within a global 'when' shadows the builtin 'len'"}, {"package main\nwhen true {\n\tlen :: 1\n}\nmain :: proc() {}\n", {}, .None, ""}, {"package main\nimport \"core:runtime\"\nmain :: proc() {}\n", {.Deprecated}, .Check_Failed, "Error: import \"core:runtime\" has been deprecated in favour of \"base:runtime\""}, {"package main\nimport \"core:runtime\"\nmain :: proc() {}\n", {}, .None, "Warning: import \"core:runtime\" has been deprecated in favour of \"base:runtime\""}}) {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)row.source), nil) { return }
		log := strings.builder_make()
		error := check_file(root, main_path, strings.to_writer(&log), context.allocator, false, nil, nil, parse_options = {vet = row.vet})
		testing.expect_value(t, error, row.error)
		testing.expect(t, strings.contains(strings.to_string(log), row.text), strings.to_string(log))
		strings.builder_destroy(&log)
	}
}

@(test)
check_command_reports_unused_procedures_and_ignores_type_switch_variables :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-unused-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	source := "package sample\nhelper :: proc() {}\nused :: proc() {}\nmain :: proc() {\n\tused()\n\tvalue: union {int, bool}\n\tswitch v in value {\n\tcase int:\n\tcase bool:\n\t}\n}\n"
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
	for row in ([]struct {
			vet:      syntax.Vet_Flags,
			packages: []string,
			error:    Driver_Error,
		}{{{.Unused_Procedures, .Unused_Variables}, {"sample"}, .Check_Failed}, {{.Unused_Procedures}, {"other"}, .None}}) {
		log := strings.builder_make()
		error := check_file(
			root,
			main_path,
			strings.to_writer(&log),
			context.allocator,
			false,
			nil,
			nil,
			parse_options = {vet = row.vet, vet_packages = row.packages},
		)
		testing.expect_value(t, error, row.error)
		text := strings.to_string(log)
		testing.expect_value(t, strings.contains(text, "'helper' declared but not used"), row.error == .Check_Failed)
		testing.expect(t, !strings.contains(text, "'used'") && !strings.contains(text, "'main'") && !strings.contains(text, "'v'"), text)
		strings.builder_destroy(&log)
	}
}

@(test)
check_command_handles_local_foreign_blocks_explicit_allocators_and_excluded_packages :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-foreign-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	package_directory, _ := filepath.join({directory, "excluded"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory(package_directory), nil) { return }
	excluded_path, _ := filepath.join({package_directory, "excluded.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(excluded_path, transmute([]byte)string("#+build darwin\npackage excluded\n")), nil) { return }
	for row in ([]struct {
			source: string,
			vet:    syntax.Vet_Flags,
			error:  Driver_Error,
			text:   string,
		}{{"package main\nforeign import libc \"system:c\"\nmain :: proc() {\n\tforeign libc {\n\t\tputs :: proc(text: cstring) -> i32 ---\n\t}\n\t_ = puts(\"\")\n}\n", {}, .None, ""}, {"package main\nimport \"excluded\"\nmain :: proc() {}\n", {}, .None, ""}, {"#+vet explicit-allocators\npackage main\nmake_value :: proc(allocator := context.allocator) {}\nmain :: proc() {\n\tmake_value()\n\tmake_value(context.allocator)\n}\n", {}, .Check_Failed, "Error: Parameter 'allocator' of type 'Allocator' must be explicitly provided in procedure call"}, {"package main\nmake_value :: proc(allocator := context.allocator) {}\nmain :: proc() { make_value() }\n", {}, .None, ""}}) {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)row.source), nil) { return }
		log := strings.builder_make()
		error := check_file(root, main_path, strings.to_writer(&log), context.allocator, false, nil, nil, parse_options = {vet = row.vet})
		testing.expect_value(t, error, row.error)
		testing.expect(t, strings.contains(strings.to_string(log), row.text), strings.to_string(log))
		strings.builder_destroy(&log)
	}
}
