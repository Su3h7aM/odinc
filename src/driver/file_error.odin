package driver

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

// A filesystem failure that names the operation, the path, and the errno. The path is cloned
// with the given allocator; the caller frees it with file_error_destroy.
File_Error :: struct {
	operation: string,
	path:      string,
	code:      os.Error,
}

record_file_error :: proc(detail: ^File_Error, operation, path: string, code: os.Error, allocator: runtime.Allocator) {
	if detail == nil { return }
	cloned, clone_error := strings.clone(path, allocator)
	if clone_error != nil { return }
	detail^ = File_Error {
		operation = operation,
		path      = cloned,
		code      = code,
	}
}

file_error_destroy :: proc(detail: ^File_Error, allocator: runtime.Allocator) {
	delete(detail.path, allocator)
	detail^ = {}
}

// Renders `cannot write 'path': reason (ERRNO)`. The reason reuses os.error_string and the errno
// name reuses the platform error's own formatting, so no per-errno table lives here.
describe_file_error :: proc(detail: File_Error, allocator := context.allocator) -> string {
	reason := os.error_string(detail.code)
	if platform, is_platform := detail.code.(os.Platform_Error); is_platform {
		return fmt.aprintf("%s '%s': %s (%v)", detail.operation, detail.path, reason, platform, allocator = allocator)
	}
	return fmt.aprintf("%s '%s': %s", detail.operation, detail.path, reason, allocator = allocator)
}
