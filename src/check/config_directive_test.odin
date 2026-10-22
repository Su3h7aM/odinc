package check

import "core:fmt"
import "core:testing"

// Each row checks the kind through its use: an integer kind divides by 3 into an int, a float kind does not.
@(test)
config_define_values_take_the_official_kind :: proc(t: ^testing.T) {
	Config_Row :: struct {
		value:    string,
		use:      string,
		complete: bool,
	}
	INT_USE :: "q: int = X / 3\n\t_ = q"
	rows := [?]Config_Row {
		{"TRUE", "b: bool = X", true},
		{"t", "b: bool = X", true},
		{"F", "b: bool = X", true},
		{"1", INT_USE, true},
		{"-12", INT_USE, true},
		{"0x10", INT_USE, true},
		{"0b101", INT_USE, true},
		{"1_000", INT_USE, true},
		{"1e3", INT_USE, true},
		{"1e-3", INT_USE, false},
		{"1.5", INT_USE, false},
		{"1.", INT_USE, false},
		{".5", "s: string = X", true},
		{"+1", "s: string = X", true},
		{"-0x10", "s: string = X", true},
		{"+1e3", "s: string = X", true},
		{"12abc", "s: string = X", true},
		{"'true'", "s: string = X", true},
	}
	for row in rows {
		source := fmt.tprintf("package sample\nX :: #config(X, 0)\nmain :: proc \"contextless\" () {{\n\t%s\n}}\n", row.use)
		defines := make(map[string]string)
		defines["X"] = row.value
		procedure, ok := check_procedure_source(t, transmute([]byte)source, defines = defines)
		delete(defines)
		if !ok { continue }
		testing.expectf(t, (procedure.body_state == .Complete) == row.complete, "--define=X=%s with %q: body %v", row.value, row.use, procedure.body_state)
	}
}

@(test)
config_define_mismatch_is_rejected_at_the_use_site :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
INT :: #config(INT, 0)
main :: proc "contextless" () {
	n: int = INT
}
`)
	defines := make(map[string]string)
	defer delete(defines)
	defines["INT"] = "abc"
	procedure, ok := check_procedure_source(t, source, defines = defines)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Invalid)
}
