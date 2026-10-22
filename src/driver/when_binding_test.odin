package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oc:check"

@(test)
package_directives_check_only_selected_when_arms :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "zz_panic_directive_*", context.temp_allocator)
	if !testing.expect(t, directory_error == nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	absolute_root, _ := filepath.abs(odin_root, context.temp_allocator)
	examples := []struct {
		source:   string,
		rejected: bool,
		message:  string,
	} {
		{`#panic("must report")`, true, "must report"},
		{`when true { when true { #panic(MESSAGE) } }; MESSAGE :: "nested"`, true, "nested"},
		{`when false { #panic("unselected") } else when true { #panic("selected") }`, true, "selected"},
		{`when true { when false { #panic("unselected") }; #assert(true) }`, false, ""},
		{`when false { #assert(false) } else { #assert(true) }`, false, ""},
		{`#assert(false)`, true, ""},
		{`#assert(size_of(Later) == 8); Later :: struct { value: u64 }`, false, ""},
		{`#assert(Later_Count == 3); Later_Count :: 1 + 2`, false, ""},
		{`#assert(offset_of(Later, value) == 0); Later :: struct { value: u64 }`, false, ""},
		{`when true { #assert(size_of(Later) == 8) }; Later :: struct { value: u64 }`, false, ""},
		{`validate :: proc() { #assert(false) }`, true, ""},
		{"validate :: proc() { #assert(true, `raw message`) }", false, ""},
		{`#panic(ODIN_ROOT)`, true, strings.concatenate({absolute_root, "/"}, context.temp_allocator)},
		{`#panic(123)`, true, ""},
	}
	for example in examples {
		source := strings.concatenate({"package main\n", example.source, "\nmain :: proc() {}\n"}, context.temp_allocator)
		if !testing.expect(t, os.write_entire_file(main_path, transmute([]byte)source) == nil) { return }
		session, err := check_program(odin_root, main_path, context.allocator, false)
		defer session_destroy(session)
		expected := Driver_Error.None
		if example.rejected { expected = .Check_Failed }
		if !testing.expectf(t, err == expected, "%s: %v", example.source, err) { continue }
		if example.message != "" {
			found := false
			for diagnostic in session.checker.diagnostics {
				if strings.contains(diagnostic.reason, example.message) { found = true }
			}
			testing.expectf(t, found, "%s: missing panic message", example.source)
		}
	}
}

@(test)
when_condition_resolves_from_later_sibling_when :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "when_retry", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator, false)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.None)
}

@(test)
when_condition_never_declared_reports_check_failure :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "when_unresolved", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator, false)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.Check_Failed)
}

@(test)
when_condition_evaluates_exists_directive_relative_to_file :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "exists_directive", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator, false)
	defer session_destroy(session)
	testing.expect_value(t, err, Driver_Error.None)
	testing.expect(t, !session.unresolved_when.set)
}

@(test)
core_thread_no_crt_constant_is_bound :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "core_thread_probe", "main.odin"}, context.temp_allocator)
	session, _ := check_program(odin_root, main_path, context.allocator, false)
	defer session_destroy(session)
	found := false
	for package_value in session.packages {
		if package_value.name != "thread" { continue }
		found = true
		scope := check.scope_get(&session.scopes, package_value.scope)
		testing.expect(t, "_IS_SUPPORTED" in scope.lookup)
	}
	testing.expect(t, found)
}
