package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oc:ir"

// A 128-bit index addresses its low word; lowering must narrow it instead of
// feeding the value's slot address to the address arithmetic.
@(test)
wide_index_reads_low_word :: proc(t: ^testing.T) {
	expect_exit(t, "wide_index_u128", 42)
}

// The bounds handler checks the index after conversion to int.
@(test)
wide_index_discards_high_word :: proc(t: ^testing.T) {
	result, ok := run_section(t, "wide_index_u128_oob")
	defer delete(result.output, context.allocator)
	if !ok { return }
	testing.expect_value(t, result.outcome, ir.Interp_Outcome.Value)
}

@(test)
constant_index_requires_a_constant_position :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-constant-index-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	cases := [?]struct {
		source:   string,
		rejected: bool,
	} {
		{"package main\nTABLE :: \"ab\"\nmain :: proc() { index := 1; _ = TABLE[index] }", true},
		{"package main\nTABLE :: [2]int{11,42}\nmain :: proc() { index := 1; _ = TABLE[index] }", true},
		{"package main\nTABLE :: []int{11,42}\nmain :: proc() { index := 1; _ = TABLE[index] }", true},
		{"package main\nTABLE :: \"ab\"\nmain :: proc() { _ = TABLE[1] }", false},
		{"package main\nTABLE :: [2]int{11,42}\nmain :: proc() { _ = TABLE[1] }", false},
		{"package main\nTABLE :: []int{11,42}\nmain :: proc() { _ = TABLE[1] }", false},
		{"package main\nTABLE :: \"ab\"\nmain :: proc() { table := TABLE; index := 1; _ = table[index] }", false},
	}
	for test in cases {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)test.source), nil) { return }
		session, err := check_program(odin_root, main_path, context.allocator)
		defer session_destroy(session)
		expected := Driver_Error.Check_Failed if test.rejected else Driver_Error.None
		if !testing.expectf(t, err == expected, "%s: %v", test.source, err) { continue }
		if test.rejected {
			found := false
			for diagnostic in session.checker.diagnostics {
				found ||= strings.contains(diagnostic.reason, "Cannot index a constant 'TABLE' with a variable index")
			}
			testing.expectf(t, found, "missing constant-index diagnostic: %s", test.source)
		}
	}
}
