package driver

import "core:testing"

// Struct ==/!= lowers through the checker's generated field-wise equality procedure.
@(test)
struct_equality_exits_with_result :: proc(t: ^testing.T) {
	expect_exit(t, "struct_equality", 255)
}
