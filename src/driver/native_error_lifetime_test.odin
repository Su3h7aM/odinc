package driver

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:lower"

@(test)
native_build_errors_remain_formatable_after_cleanup :: proc(t: ^testing.T) {
	source := `package main
foreign {
	missing_external :: proc "c" () ---
}
main :: proc() {
	missing_external()
}
`
	directory, directory_error := os.make_directory_temp("", "driver-error-lifetime-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	source_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(source_path, transmute([]byte)source), nil) { return }
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, build_error := build_file(odin_root, source_path, strings.to_writer(&build_log), context.allocator, 1)
	if !testing.expect(t, image == nil && build_error != nil) { return }
	defer delete(image)
	if !testing.expect(t, strings.contains(strings.to_string(build_log), "missing_external")) { return }
	#partial switch value in build_error {
	case Link_Failed:
	case:
		testing.expectf(t, false, "expected Link_Failed, got %v", build_error)
		return
	}
	formatted_error: strings.Builder
	defer strings.builder_destroy(&formatted_error)
	fmt.sbprintf(&formatted_error, "%v", build_error)
	testing.expect(t, len(strings.to_string(formatted_error)) > 0)
}

@(test)
foreign_library_requests_keep_declaration_identity :: proc(t: ^testing.T) {
	source := `package main
foreign import absent "/missing/unused-foreign-library.a"
foreign import used "system:c"
foreign absent {
	@(link_name="puts") unused_puts :: proc "c" (text: cstring) -> i32 ---
}
foreign used {
	puts :: proc "c" (text: cstring) -> i32 ---
	environ: rawptr
}
callback := puts
environment := &environ
main :: proc() {
	puts("")
	_ = callback
	_ = environment
}
`
	directory, directory_error := os.make_directory_temp("", "driver-foreign-reachability-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	source_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(source_path, transmute([]byte)source), nil) { return }
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	session, session_error := check_program(odin_root, source_path, context.allocator, false)
	defer session_destroy(session)
	if !testing.expect_value(t, session_error, Driver_Error.None) { return }
	module: ir.Module
	errors, required, lower_error := lower.lower_program(&session.program, &module, context.allocator)
	defer delete(errors)
	defer ir.module_destroy(&module)
	if !testing.expectf(t, lower_error == nil && len(errors) == 0, "%v %v", lower_error, errors) { return }
	puts_reached, environ_reached: bool
	for symbol in required {
		declaration := check.symbols(&session.program)[int(symbol) - 1]
		library := session.program.entities[declaration.library]
		testing.expect(t, library.name != "absent")
		if declaration.name == "puts" { puts_reached = true }
		if declaration.name == "environ" { environ_reached = true }
	}
	testing.expect(t, puts_reached && environ_reached)
	puts_count := 0
	for extern in module.externs { if extern.name == "puts" { puts_count += 1 } }
	testing.expect_value(t, puts_count, 1)
	rejected, rejected_error := load_foreign_files(&session.program, required, odin_root, .Linux, false, context.allocator)
	defer foreign_files_destroy(&rejected)
	if failure, ok := rejected_error.(Foreign_Library_Failed); testing.expect(t, ok) {
		testing.expect_value(t, failure.reason, "requires managed profile but session uses no-crt")
	}
	non_linux, non_linux_error := load_foreign_files(&session.program, required, odin_root, .Darwin, false, context.allocator)
	defer foreign_files_destroy(&non_linux)
	testing.expect_value(t, non_linux_error, nil)
	files, library_error := load_foreign_files(&session.program, required, odin_root, session.build.os, session.managed_libc, context.allocator)
	defer foreign_files_destroy(&files)
	testing.expect_value(t, library_error, nil)
}

@(test)
constant_slices_materialize_independent_writable_backing :: proc(t: ^testing.T) {
	source := `package main
import "base:intrinsics"
GLOBAL := []int{4,5}
NESTED := [][]int{{6,7}, {8,9}}
main :: proc() {
    A :: []int{1, 0, 3}
    B := A
    B[0] = 9
    C :: [][]int{{1,2}, {3,4}}
    D := C
    D[0][0] = 8
    E :: [2][]int{{5,6}, {7,8}}
    F := E
    F[0][0] = 11
    sum := 0
    for x in A { sum += x }
    GLOBAL[0] = 7
    NESTED[0][0] = 12
    if A[0] != 1 || B[0] != 9 || C[0][0] != 1 || D[0][0] != 8 || E[0][0] != 5 || F[0][0] != 11 || sum != 4 || len(A) != 3 || GLOBAL[0] != 7 || NESTED[0][0] != 12 {
        intrinsics.syscall(60, 1)
    }
    intrinsics.syscall(60, 0)
}
`
	directory, directory_error := os.make_directory_temp("", "driver-constant-slices-*", context.temp_allocator)
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
	path, _ := filepath.join({directory, "slices"}, context.temp_allocator)
	if !testing.expect_value(t, write_executable(path, image), nil) { return }
	output_path, _ := filepath.join({directory, "output"}, context.temp_allocator)
	devnull, open_error := os.open("/dev/null", {.Write})
	if !testing.expect_value(t, open_error, nil) { return }
	defer os.close(devnull)
	state, output, output_open_error, process_error, wait_error, output_error := run_raw_data_child(path, output_path, devnull)
	testing.expect(t, output_open_error == nil && process_error == nil && wait_error == nil && output_error == nil)
	testing.expectf(t, state.exit_code == 0, "constant slice fixture exited %d", state.exit_code)
	testing.expect_value(t, len(output), 0)
}
