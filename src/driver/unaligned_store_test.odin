package driver

import "core:testing"

@(test)
unaligned_store_preserves_scalars_and_aggregates :: proc(t: ^testing.T) {
	expect_exit(t, "unaligned_store", 73)
}
