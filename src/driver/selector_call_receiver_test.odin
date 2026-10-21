package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

// `base->field(...)` passes the owner of the field as the first argument, once, with named and default arguments
// after it, through by-value, pointer, rawptr and `using`-promoted owners.
@(test)
selector_call_passes_the_field_owner_once :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "selector_call_receiver", 127)
}
