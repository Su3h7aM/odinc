package driver

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "oc:elf"

@(test)
native_library_profiles :: proc(t: ^testing.T) {
	cases := [?]struct { source: string, dynamic_image: bool } {
		{`package main
#assert(ODIN_NO_CRT)
main :: proc() {}`, false},
		{`package main
@(private, export, link_name="private_export_value") owned: int
foreign { @(link_name="private_export_value") alias: int }
#assert(ODIN_NO_CRT)
main :: proc() { _ = alias }`, false},
		{`package main
import "core:fmt"
#assert(ODIN_NO_CRT)
main :: proc() { fmt.println("hello") }`, false},
		{`package main
import "core:os"
#assert(ODIN_NO_CRT)
main :: proc() { _ = os.args }`, false},
		{`package main
import "core:strings"
#assert(ODIN_NO_CRT)
main :: proc() { _ = strings.contains("abc", "b") }`, false},
		{`package main
foreign import c "system:c"
foreign c { puts :: proc "c" (s: cstring) -> i32 --- }
#assert(ODIN_NO_CRT)
main :: proc() {}`, false},
		{`package main
import "core:fmt"
foreign import c "system:c"
foreign c { puts :: proc "c" (s: cstring) -> i32 --- }
main :: proc() { _ = puts("hello"); when ODIN_NO_CRT { fmt.println("wrong-profile") } else { fmt.println("managed") } }`, true},
		{`package main
foreign import c "system:c"
foreign c { puts :: proc "c" (s: cstring) -> i32 --- }
#assert(!ODIN_NO_CRT)
main :: proc() { _ = puts("hello") }`, true},
		{`package main
foreign import c "system:c"
foreign c { puts :: proc "c" (s: cstring) -> i32 --- }
main :: proc() { #assert(!ODIN_NO_CRT); _ = puts("hello") }`, true},
		{`package main
foreign import c "system:c"
foreign c { puts :: proc "c" (s: cstring) -> i32 --- }
#assert(ODIN_NO_CRT)
unused :: proc() { _ = puts("hello") }
main :: proc() {}`, false},
	}
	directory, directory_error := os.make_directory_temp("", "driver-profile-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	source_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	for sample in cases {
		if !testing.expect_value(t, os.write_entire_file(source_path, transmute([]byte)sample.source), nil) { continue }
		log: strings.Builder
		image, err := build_file(root, source_path, strings.to_writer(&log), context.allocator, 1)
		if !testing.expectf(t, err == nil, "%v: %s", err, strings.to_string(log)) {
			strings.builder_destroy(&log)
			continue
		}
		strings.builder_destroy(&log)
		defer delete(image)
		header := slice.reinterpret([]elf.File_Header, image)[0]
		headers := slice.reinterpret([]elf.Program_Header, image[int(header.e_phoff):])[:int(header.e_phnum)]
		dynamic_image := false
		for segment in headers { if u32(segment.p_type) == elf.PT_DYNAMIC { dynamic_image = true } }
		testing.expect_value(t, dynamic_image, sample.dynamic_image)
	}
}
