
package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "oc:amd64"

process_lock: sync.Mutex

write_executable :: proc(path: string, image: []byte) -> os.Error {
	sync.mutex_lock(&process_lock)
	defer sync.mutex_unlock(&process_lock)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	return os.write_entire_file(path, image, permissions)
}

start_process :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	sync.mutex_lock(&process_lock)
	defer sync.mutex_unlock(&process_lock)
	return os.process_start(desc)
}

run_raw_data_child :: proc(
	path, output_path: string,
	stderr: ^os.File,
) -> (
	state: os.Process_State,
	output: []byte,
	open_error, process_error, wait_error, output_error: os.Error,
) {
	stdout: ^os.File
	stdout, open_error = os.open(output_path, {.Write, .Create, .Trunc})
	if open_error != nil { return }
	defer _ = os.close(stdout)
	process: os.Process
	process, process_error = start_process(os.Process_Desc{command = []string{path}, stdout = stdout, stderr = stderr})
	if process_error != nil { return }
	state, wait_error = os.process_wait(process)
	output, output_error = os.read_entire_file_from_path(output_path, context.temp_allocator)
	return
}

NativeSectionExpectation :: struct {
	section: string,
	code:    int,
}

native_section_expectations := [?]NativeSectionExpectation {
	{"procedure_static_defaults", 0},
	{"procedure_static_identity", 0},
	{"procedure_static_callers", 0},
	{"section_20", 5},
	{"section_21", 127},
	{"section_22", 71},
	{"section_23", 200},
	{"section_24", 122},
	{"section_25", 37},
	{"section_26", 47},
	{"section_28", 128},
	{"section_29", 15},
	{"section_30", 26},
	{"section_31", 5},
	{"section_32", 100},
	{"range_loops", 0},
	{"range_loops_more", 0},
	{"or_else", 50},
	{"or_return", 0},
	{"or_break", 73},
	{"or_continue", 0},
	{"unreachable", 0},
	{"raw_data", 127},
	{"memory_misc", 7},
	{"uninitialized", 37},
	{"enum_extrema", 31},
	{"numeric_builtins", 127},
	{"bit_ops", 31},
	{"constant_log2", 31},
	{"composite_literals", 51},
	{"procedure_literals", 51},
	{"type_info_of", 31},
	{"atomics", 127},
	{"multiple_assignment", 127},
	{"bit_field", 63},
	{"map_cell_info", 15},
	{"map_info", 63},
	{"map_literal", 0},
	{"type_hasher_proc", 63},
	{"type_hasher_cstring", 63},
	{"named_arguments", 36},
	{"type_predicates", 255},
	{"pointer_arithmetic", 59},
	{"entry_point_noop", 7},
	{"x86_raw_operations", 7},
	{"atomic_pointers", 14},
	{"main_implicit_context", 0},
	{"variadic_defaults", 28},
	{"polymorphic_records", 127},
	{"type_assertions", 255},
	{"demo_section_implicit_selector_expression", 3},
	{"demo_section_the_basics", 14},
	{"demo_section_control_flow", 22},
	{"demo_section_named_proc_return_parameters", 11},
	{"demo_section_variadic_procedures", 9},
	{"demo_section_explicit_procedure_overloading", 5},
	{"demo_section_struct_type", 13},
	{"demo_section_implicit_context_system", 5},
	{"demo_section_parametric_polymorphism", 8},
	{"demo_section_unroll_for_statement", 75},
	{"demo_section_deprecated_attribute", 5},
	{"demo_section_union_maybe", 248},
	{"demo_section_union_type", 12},
	{"demo_section_explicit_context_definition", 7},
	{"demo_section_bit_field_type", 30},
	{"demo_section_range_statements_with_multiple_return_values", 55},
	{"matrix_procedure_abi", 0},
	{"atomic_bool", 127},
	{"literal_aggregates", 255},
	{"struct_equality", 255},
	{"reflect_enum_string", 0},
	{"range_reference", 91},
	{"global_dynamic_literal", 0},
	{"intrinsic_alloca_hint", 7},
	{"pointer_order", 7},
	{"generated_half_compare", 31},
}

native_section_test_directory :: proc(t: ^testing.T) -> string {
	directory, directory_err := os.make_directory_temp("", "driver-native-*", context.temp_allocator)
	testing.expect(t, directory_err == nil, "temporary directory must be created")
	return directory
}

check_native_section :: proc(t: ^testing.T, odin_root, directory: string, section: string, code: int) {
	main_path, _ := filepath.join({#directory, "testdata", section, "main.odin"}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, err := build_file(odin_root, main_path, strings.to_writer(&build_log), context.allocator, 1)
	if !testing.expectf(t, err == nil, "%s: %v\n%s", section, err, strings.to_string(build_log)) { return }
	defer delete(image)
	path, _ := filepath.join({directory, section}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil, "executable must be written") { return }
	if section == "raw_data" {
		devnull, devnull_err := os.open("/dev/null", {.Write})
		if !testing.expect(t, devnull_err == nil, "devnull must open") { return }
		defer _ = os.close(devnull)
		output_path, _ := filepath.join({directory, "raw_data.stdout"}, context.temp_allocator)
		state, output, open_err, process_err, wait_err, output_err := run_raw_data_child(path, output_path, devnull)
		if !testing.expect(t, open_err == nil, "raw_data stdout file must open") { return }
		if !testing.expect(t, process_err == nil, "raw_data process must start") { return }
		testing.expectf(t, wait_err == nil && state.exit_code == code, "raw_data exited %d, expected %d: %v", state.exit_code, code, wait_err)
		testing.expect(t, output_err == nil && string(output) == "!", "raw_data operand side effect must run once")
		return
	}
	devnull, devnull_err := os.open("/dev/null", {.Write})
	testing.expect(t, devnull_err == nil, "devnull must open")
	defer _ = os.close(devnull)
	process, process_err := start_process(os.Process_Desc{command = []string{path}, stdout = devnull, stderr = devnull})
	if !testing.expect(t, process_err == nil, "process must start") { return }
	state, wait_err := os.process_wait(process)
	testing.expectf(t, wait_err == nil && state.exit_code == code, "%s exited %d, expected %d: %v", section, state.exit_code, code, wait_err)
}

@(test)
native_sections_group_1 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[0:8] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_sections_group_2 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[8:16] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_sections_group_3 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[16:24] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_sections_group_4 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[24:32] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_sections_group_5 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[32:39] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_sections_group_6 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[39:46] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_sections_group_7 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[46:53] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_sections_group_8 :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	for entry in native_section_expectations[53:] {
		check_native_section(t, odin_root, directory, entry.section, entry.code)
	}
}

@(test)
native_startup_initializes_auxv_across_arguments_and_environment :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "startup_args", "main.odin"}, context.temp_allocator)
	image, err := build_file(odin_root, main_path, {}, context.allocator, 1)
	if !testing.expectf(t, err == nil, "startup fixture must build: %v", err) { return }
	defer delete(image)
	directory, directory_err := os.make_directory_temp("", "driver-startup-*", context.temp_allocator)
	if !testing.expect(t, directory_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	path, _ := filepath.join({directory, "startup"}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil, "startup executable must be written") { return }
	devnull, devnull_err := os.open("/dev/null", {.Write})
	if !testing.expect(t, devnull_err == nil, "devnull must open") { return }
	defer _ = os.close(devnull)
	commands := [?][3]string{{path, "first", "second"}, {path, "third", "fourth"}}
	environments := [?][]string{{"NABLA_STARTUP_TEST=present"}, {}}
	for index in 0 ..< len(commands) {
		process, process_err := start_process(os.Process_Desc{command = commands[index][:], env = environments[index], stdout = devnull, stderr = devnull})
		if !testing.expect(t, process_err == nil, "startup process must start") { continue }
		state, wait_err := os.process_wait(process)
		testing.expect(t, wait_err == nil && state.exit_code == 0, "runtime init must accept argv and environment")
	}
}

@(test)
startup_initializes_runtime_args_header_before_global_initializer :: proc(t: ^testing.T) {
	init_symbol := Maybe(u32)(2)
	atom, err := amd64.emit_linux_entry(
		amd64.Linux_Entry_Symbols{main = 1, init = init_symbol, default_context = 3, args = 4, argc = 5, argv = 6, envp = 7, thread_pointer = 8},
		context.allocator,
	)
	if !testing.expect_value(t, err, nil) { return }
	defer delete(atom.bytes, context.allocator)
	defer delete(atom.relocs, context.allocator)
	data_offset, length_offset, init_offset := -1, -1, -1
	for relocation in atom.relocs {
		if relocation.symbol == 4 && relocation.addend == -4 { data_offset = int(relocation.offset) }
		if relocation.symbol == 4 && relocation.addend == 4 { length_offset = int(relocation.offset) }
		if relocation.symbol == 2 { init_offset = int(relocation.offset) }
	}
	testing.expect(t, data_offset >= 0 && length_offset >= 0, "runtime.args__ data and length relocations must target its resolved global")
	testing.expect(t, data_offset < init_offset && length_offset < init_offset, "runtime.args__ must be initialized before package initializers")
}
