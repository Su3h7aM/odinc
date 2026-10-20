package check

import "core:testing"

@(test)
invalid_declared_types_suppress_operand_diagnostics :: proc(t: ^testing.T) {
	// Official reports only the two undeclared type names, with no errors at their uses.
	source := transmute([]byte)string(
		`package sample
global: Missing_Global_Type
main :: proc "contextless" () {
	local: Missing_Local_Type
	local.field = 1
	_ = local + local
	_ = local[0]
	global.field = 1
	_ = global + global
	_ = global[0]
}
`,
	)
	_, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 2)
	testing.expect(t, ok)
}
