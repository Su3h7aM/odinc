package driver

import "core:testing"

@(test)
matrix_casts_convert_elements_in_layout_order :: proc(t: ^testing.T) {
	expect_exit(t, "matrix_cast", 0)
}
