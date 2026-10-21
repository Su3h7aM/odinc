package driver

import "core:testing"

@(test)
matrix_procedure_arguments_and_results_cross_call_boundaries :: proc(t: ^testing.T) {
	expect_exit(t, "matrix_procedure_abi", 0)
}
