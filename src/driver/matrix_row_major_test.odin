package driver

import "core:testing"

@(test)
matrix_row_major_layout_reads_elements_in_row_order :: proc(t: ^testing.T) {
	expect_exit(t, "matrix_row_major_layout", 0)
}
