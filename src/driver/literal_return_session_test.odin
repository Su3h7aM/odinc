package driver

import "core:path/filepath"
import "core:testing"

@(test)
string_literal_escapes_raw_and_triple_quoted_decode_to_their_lengths :: proc(t: ^testing.T) {
	expect_exit(t, "string_literals", 41)
}

// Checks that `return pair()` is accepted for a two-result procedure. Lowering that call is covered natively.
@(test)
returned_call_results_check_for_multiple_result_procedure :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "return_call", "main.odin"}, context.temp_allocator)
	session, err := check_program(odin_root, main_path, context.allocator, false)
	defer session_destroy(session)
	testing.expectf(t, err == .None, "%v %v", err, session.checker.diagnostics)
}
