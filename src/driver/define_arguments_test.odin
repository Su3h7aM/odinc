package driver

import "core:testing"

@(test)
malformed_define_arguments_report_the_official_message :: proc(t: ^testing.T) {
	defines := make(map[string]string)
	defer delete(defines)
	malformed := [?][2]string{{"X", "Expected 'name=value', got 'X'"}, {"X=", "Expected 'name=value', got 'X='"}, {"", "Flag missing for 'define'"}}
	for row in malformed {
		testing.expect_value(t, parse_define_argument(&defines, row[0]), Driver_Error.Invalid_Define)
		testing.expect_value(t, define_argument_error_message(row[0]), row[1])
	}
	testing.expect_value(t, parse_define_argument(&defines, "X=1"), Driver_Error.None)
	testing.expect_value(t, defines["X"], "1")
}
