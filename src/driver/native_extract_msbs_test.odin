package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
native_simd_extract_msbs_preserves_raw_lane_bits :: proc(t: ^testing.T) {
	source := `package main
import "core:simd"
U8x16 :: #simd[16]u8
calls: int
produce :: proc() -> U8x16 {
	calls += 1
	return U8x16{3, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 3}
}
main :: proc() {
	mask := transmute(u16)simd.extract_msbs(simd.lanes_eq(produce(), U8x16(3)))
	assert(mask == 0x8009 && calls == 1)
	signed := #simd[4]i32{-1, 0, -7, 1}
	assert(transmute(u8)simd.extract_msbs(signed) == 5)
	raw := #simd[4]u8{0x80, 1, 0xff, 0}
	booleans := transmute(#simd[4]bool)raw
	assert(transmute(u8)simd.extract_msbs(booleans) == 5)
	wide_elements := #simd[2]u128{u128(1) << 127, u128(1) << 63}
	assert(transmute(u8)simd.extract_msbs(wide_elements) == 1)
	bytes: [64]u8
	bytes[0], bytes[31], bytes[63] = 0x80, 0x80, 0x80
	boundary := transmute(#simd[64]u8)bytes
	bits := transmute(u64)simd.extract_msbs(boundary)
	assert(bits == u64(1) | (u64(1) << 31) | (u64(1) << 63))
}
`
	directory, directory_error := os.make_directory_temp("", "driver-extract-msbs-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	source_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(source_path, transmute([]byte)source), nil) { return }
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, build_error := build_file(odin_root, source_path, strings.to_writer(&build_log), context.allocator, 1)
	if !testing.expectf(t, build_error == nil, "%v: %s", build_error, strings.to_string(build_log)) { return }
	defer delete(image)
	path, _ := filepath.join({directory, "extract_msbs"}, context.temp_allocator)
	if !testing.expect_value(t, write_executable(path, image), nil) { return }
	output_path, _ := filepath.join({directory, "output"}, context.temp_allocator)
	devnull, open_error := os.open("/dev/null", {.Write})
	if !testing.expect_value(t, open_error, nil) { return }
	defer os.close(devnull)
	state, output, output_open_error, process_error, wait_error, output_error := run_raw_data_child(path, output_path, devnull)
	testing.expect(t, output_open_error == nil && process_error == nil && wait_error == nil && output_error == nil)
	testing.expectf(t, state.exit_code == 0, "extract_msbs fixture exited %d", state.exit_code)
	testing.expect_value(t, len(output), 0)
}
