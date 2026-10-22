package driver

import "core:testing"

@(test)
partial_integer_abi_pieces_preserve_object_bytes :: proc(t: ^testing.T) {
	expect_exit(t, "partial_abi_pieces", 31)
}
