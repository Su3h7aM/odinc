package driver

import "core:testing"

@(test)
target_selection_follows_linux_amd64 :: proc(t: ^testing.T) {
	testing.expect(t, !target_source_excluded("heap.odin", "package x\n"))
	testing.expect(t, !target_source_excluded("heap_linux.odin", ""))
	testing.expect(t, !target_source_excluded("heap_linux_amd64.odin", ""))
	testing.expect(t, target_source_excluded("heap_windows.odin", ""))
	testing.expect(t, target_source_excluded("heap_linux_arm64.odin", ""))
	testing.expect(t, target_source_excluded("heap.odin", "#+build windows\npackage x\n"))
	testing.expect(t, !target_source_excluded("heap.odin", "#+build linux, windows\npackage x\n"))
	testing.expect(t, target_source_excluded("heap.odin", "#+build !linux\npackage x\n"))
}
