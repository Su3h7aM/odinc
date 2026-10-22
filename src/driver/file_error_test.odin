package driver

import "core:os"
import "core:strings"
import "core:testing"

@(test)
file_error_describes_filesystem_failure :: proc(t: ^testing.T) {
	path := "/nonexistent-odinc-directory-9f3/main.odin"
	_, stat_error := os.stat(path, context.temp_allocator)
	testing.expect(t, stat_error != nil, "stat of a missing path must fail")
	if stat_error == nil { return }
	message := describe_file_error(File_Error{operation = "cannot stat", path = path, code = stat_error}, context.temp_allocator)
	testing.expect(t, strings.has_prefix(message, "cannot stat"), "message must name the operation")
	testing.expect(t, strings.contains(message, path), "message must name the path")
	when ODIN_OS == .Linux {
		// 26 is ETXTBSY, the errno from rebuilding onto a running program.
		busy := describe_file_error(File_Error{operation = "cannot write", path = "build/nabla", code = os.Platform_Error(26)}, context.temp_allocator)
		testing.expect_value(t, busy, "cannot write 'build/nabla': Text file busy (ETXTBSY)")
	}
}
