package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

// Exit-code checksum over non-empty dynamic array and map literals: lengths,
// capacities, appended and inserted elements, and an order-independent map sum.
// Every check contributes one bit, so the binary exits 255 only when all pass.
@(test)
literal_aggregates_exit_with_checksum :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "literal_aggregates", 255)
}
