package driver

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
core_thread_selected_files_linux_amd64 :: proc(t: ^testing.T) {
	directory, join_error := filepath.join({#directory, "..", "..", "core", "thread"}, context.temp_allocator)
	testing.expect(t, join_error == nil)
	handle, open_error := os.open(directory)
	testing.expect(t, open_error == nil)
	defer os.close(handle)
	infos, read_error := os.read_dir(handle, -1, context.temp_allocator)
	testing.expect(t, read_error == nil)

	selected: [dynamic]string
	defer delete(selected)
	for info in infos {
		if info.type == .Directory || !strings.has_suffix(info.name, ".odin") || strings.has_suffix(info.name, "_test.odin") { continue }
		source, source_error := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		testing.expect(t, source_error == nil)
		if !target_source_excluded(info.name, string(source)) { append(&selected, info.name) }
	}
	slice.sort(selected[:])
	testing.expect(t, slice.contains(selected[:], "thread.odin"))
	testing.expect(t, slice.contains(selected[:], "thread_unix.odin"))
	testing.expect(t, slice.contains(selected[:], "thread_linux_no_crt.odin"))
	testing.expect(t, !slice.contains(selected[:], "thread_other.odin"))
	testing.expect(t, !slice.contains(selected[:], "thread_windows.odin"))
}
