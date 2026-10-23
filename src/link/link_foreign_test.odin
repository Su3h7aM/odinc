package link

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oc:elf"

write_text :: proc(path, text: string) -> bool {
	bytes := make([]byte, len(text))
	defer delete(bytes)
	copy(bytes, text)
	return os.write_entire_file(path, bytes) == nil
}

clang_object :: proc(t: ^testing.T, directory, name, source: string, args: []string) -> []byte {
	source_name := strings.concatenate({name, ".c"}, context.temp_allocator)
	object_name := strings.concatenate({name, ".o"}, context.temp_allocator)
	source_path, source_err := filepath.join({directory, source_name}, context.temp_allocator)
	object_path, object_err := filepath.join({directory, object_name}, context.temp_allocator)
	testing.expect(t, source_err == nil && object_err == nil, "clang paths must be joined")
	testing.expect(t, write_text(source_path, source), "source must be written")
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "clang")
	append(&command, "-c")
	append(&command, "-fno-asynchronous-unwind-tables")
	append(&command, "-fno-stack-protector")
	for arg in args {
		append(&command, arg)
	}
	append(&command, source_path)
	append(&command, "-o")
	append(&command, object_path)
	devnull, devnull_err := os.open("/dev/null", {.Write})
	testing.expect(t, devnull_err == nil, "devnull must open")
	defer _ = os.close(devnull)
	process, start_err := start_process({command = command[:], stdout = devnull, stderr = devnull})
	testing.expect(t, start_err == nil, "clang must start")
	state, wait_err := os.process_wait(process)
	testing.expect(t, wait_err == nil && state.exit_code == 0, "clang must compile the source")
	bytes, read_err := os.read_entire_file(object_path, context.allocator)
	testing.expect(t, read_err == nil, "object must be read")
	return bytes
}

run_command_capture :: proc(t: ^testing.T, directory, output_name: string, command: []string) -> string {
	output_path, path_err := filepath.join({directory, output_name}, context.temp_allocator)
	testing.expect(t, path_err == nil, "output path must be joined")
	output, open_err := os.open(output_path, {.Write, .Create, .Trunc})
	testing.expect(t, open_err == nil, "output file must be created")
	process, start_err := start_process({command = command, stdout = output})
	testing.expect(t, start_err == nil, "command must start")
	state, wait_err := os.process_wait(process)
	os.close(output)
	testing.expect(t, wait_err == nil && state.exit_code == 0, "command must succeed")
	bytes, read_err := os.read_entire_file(output_path, context.temp_allocator)
	testing.expect(t, read_err == nil, "command output must be read")
	return string(bytes)
}

@(test)
clang_objects_resolve_weak_common_comdat_and_tls :: proc(t: ^testing.T) {
	directory, dir_err := os.make_directory_temp("", "link-foreign-*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)

	first := clang_object(
		t,
		directory,
		"first",
		"inline int twice(int value) { return value + value; }\nint use_first(void) { return twice(0); }\n",
		{"-xc++"},
	)
	second := clang_object(
		t,
		directory,
		"second",
		"inline int twice(int value) { return value + value; }\nextern \"C\" int use_twice(void) { return twice(1); }\n",
		{"-xc++"},
	)
	tentative := clang_object(t, directory, "tentative", "int strong_value = 3;\n__attribute__((weak)) int weak_value = 1;\nint common_value;\n", {"-fcommon"})
	defined := clang_object(t, directory, "defined", "int weak_value = 4;\nint common_value = 2;\n", {})
	start := clang_object(
		t,
		directory,
		"start",
		"extern int strong_value, weak_value, common_value;\nextern \"C\" int use_twice(void);\nextern \"C\" void _start(void) { long code = strong_value + weak_value + common_value + use_twice(); __asm__ volatile(\"mov %0, %%rdi; mov $60, %%rax; syscall\" : : \"r\"(code) : \"rax\", \"rdi\"); }\n",
		{"-xc++"},
	)
	defer delete(first)
	defer delete(second)
	defer delete(tentative)
	defer delete(defined)
	defer delete(start)

	first_input, first_err := read_object(first, context.allocator)
	second_input, second_err := read_object(second, context.allocator)
	tentative_input, tentative_err := read_object(tentative, context.allocator)
	defined_input, defined_err := read_object(defined, context.allocator)
	start_input, start_err := read_object(start, context.allocator)
	testing.expect(t, first_err == nil && second_err == nil && tentative_err == nil && defined_err == nil && start_err == nil, "objects must be read")
	image, link_err := link({first_input, second_input, tentative_input, defined_input, start_input}, "_start", context.allocator)
	testing.expectf(t, link_err == nil, "comdat objects must link: %v", link_err)
	if link_err != nil { return }
	defer delete(image)
	run_executable_expect_exit(t, image, 11)

	inputs := [?]Input{first_input, second_input}
	kept := 0
	for input in inputs {
		for symbol in input.symbols {
			if symbol.name != "_Z5twicei" || symbol.atom == ATOM_UNDEFINED {
				continue
			}
			if !input.atoms[symbol.atom].discarded {
				kept += 1
			}
		}
	}
	testing.expect(t, kept == 1, "one comdat copy of twice must remain")
	input_destroy(&first_input, context.allocator)
	input_destroy(&second_input, context.allocator)
	input_destroy(&tentative_input, context.allocator)
	input_destroy(&defined_input, context.allocator)
	input_destroy(&start_input, context.allocator)

	tls := clang_object(t, directory, "tls", "__thread int tls_value = 7;\n", {})
	defer delete(tls)
	tls_code := [?]byte {
		0xbf,
		0x02,
		0x10,
		0,
		0,
		0xbe,
		0,
		0,
		0,
		0,
		0xb8,
		158,
		0,
		0,
		0,
		0x0f,
		0x05,
		0x64,
		0x8b,
		0x04,
		0x25,
		0,
		0,
		0,
		0,
		0x89,
		0xc7,
		0xb8,
		231,
		0,
		0,
		0,
		0x0f,
		0x05,
	}
	tls_relocs := []Relocation{{offset = 6, symbol = 1, kind = .R_X86_64_32, addend = 8}, {offset = 21, symbol = 1, kind = .R_X86_64_TPOFF32}}
	tls_start := Input {
		atoms   = {{section = .Text, align = 16, bytes = tls_code[:], size = u64(len(tls_code)), relocs = tls_relocs}},
		symbols = {{name = "_start", atom = 0}, {name = "tls_value", atom = ATOM_UNDEFINED}},
	}
	tls_input, tls_err := read_object(tls, context.allocator)
	testing.expect(t, tls_err == nil, "tls object must be read")
	tls_image, tls_link_err := link({tls_start, tls_input}, "_start", context.allocator)
	testing.expect(t, tls_link_err == nil, "tls object must link")
	defer delete(tls_image)
	run_executable_expect_exit(t, tls_image, 7)
	input_destroy(&tls_input, context.allocator)
}

@(test)
archive_extracts_the_referenced_member :: proc(t: ^testing.T) {
	directory, dir_err := os.make_directory_temp("", "link-archive-*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	used := clang_object(t, directory, "used", "int pick(void) { return 4; }\n", {})
	unused := clang_object(t, directory, "unused", "extern int missing(void);\nint unused(void) { return missing(); }\n", {})
	defer delete(used)
	defer delete(unused)
	start := clang_object(
		t,
		directory,
		"start",
		"extern int pick(void);\nvoid _start(void) { long code = pick(); __asm__ volatile(\"mov %0, %%rdi; mov $60, %%rax; syscall\" : : \"r\"(code) : \"rax\", \"rdi\"); }\n",
		{},
	)
	defer delete(start)

	archive_path, archive_err := filepath.join({directory, "lib.a"}, context.temp_allocator)
	used_path, used_err := filepath.join({directory, "used.o"}, context.temp_allocator)
	unused_path, unused_err := filepath.join({directory, "unused.o"}, context.temp_allocator)
	testing.expect(t, archive_err == nil && used_err == nil && unused_err == nil, "archive paths must be joined")
	devnull, devnull_err := os.open("/dev/null", {.Write})
	testing.expect(t, devnull_err == nil, "devnull must open")
	defer _ = os.close(devnull)
	process, start_err := start_process({command = []string{"llvm-ar", "rcs", archive_path, used_path, unused_path}, stdout = devnull, stderr = devnull})
	testing.expect(t, start_err == nil, "llvm-ar must start")
	state, wait_err := os.process_wait(process)
	testing.expect(t, wait_err == nil && state.exit_code == 0, "llvm-ar must write the archive")
	archive_bytes, read_err := os.read_entire_file(archive_path, context.allocator)
	testing.expect(t, read_err == nil, "archive must be read")
	defer delete(archive_bytes)

	image, link_err := link_files([][]byte{start}, [][]byte{archive_bytes}, {}, "_start", context.allocator)
	testing.expect(t, link_err == nil, "archive must supply pick")
	defer delete(image)
	run_executable_expect_exit(t, image, 4)
}

@(test)
shared_library_and_got_relaxation :: proc(t: ^testing.T) {
	directory, dir_err := os.make_directory_temp("", "link-dynamic-*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	source_path, source_err := filepath.join({directory, "shared.c"}, context.temp_allocator)
	library_path, library_err := filepath.join({directory, "libanswer.so"}, context.temp_allocator)
	testing.expect(t, source_err == nil && library_err == nil, "shared paths must be joined")
	testing.expect(t, write_text(source_path, "int shared_value = 5;\nint answer(void) { return 42; }\n"), "shared source must be written")
	devnull, devnull_err := os.open("/dev/null", {.Write})
	testing.expect(t, devnull_err == nil, "devnull must open")
	defer _ = os.close(devnull)
	process, start_err := start_process(
		{
			command = []string{"clang", "-shared", "-fPIC", "-fno-asynchronous-unwind-tables", source_path, "-o", library_path},
			stdout = devnull,
			stderr = devnull,
		},
	)
	testing.expect(t, start_err == nil, "clang must start")
	state, wait_err := os.process_wait(process)
	testing.expect(t, wait_err == nil && state.exit_code == 0, "shared library must be built")
	library_bytes, library_read_err := os.read_entire_file(library_path, context.allocator)
	testing.expect(t, library_read_err == nil, "shared library must be read")
	defer delete(library_bytes)
	shared, shared_err := shared_library_read(library_bytes, library_path, context.allocator)
	testing.expect(t, shared_err == nil, "dynamic symbols must be read")
	defer shared_library_destroy(&shared)

	main := clang_object(
		t,
		directory,
		"main",
		"extern int shared_value;\nextern int answer(void);\nvoid _start(void) { long code = answer() + shared_value; __asm__ volatile(\"mov %0, %%rdi; mov $60, %%rax; syscall\" : : \"r\"(code) : \"rax\", \"rdi\"); }\n",
		{"-fPIC"},
	)
	defer delete(main)
	image, link_err := link_files([][]byte{main}, {}, []Shared_Library{shared}, "_start", context.allocator)
	testing.expect(t, link_err == nil, "dynamic program must link")
	defer delete(image)
	run_executable_expect_exit(t, image, 47)

	executable_path, path_err := filepath.join({directory, "dynamic"}, context.temp_allocator)
	testing.expect(t, path_err == nil && os.write_entire_file(executable_path, image) == nil, "dynamic image must be written")
	dump := run_command_capture(t, directory, "readelf.txt", []string{"llvm-readelf", "-d", "-l", executable_path})
	testing.expect(
		t,
		strings.contains(dump, DEFAULT_INTERPRETER) && strings.contains(dump, "NEEDED") && strings.contains(dump, "JMPREL"),
		"dynamic program headers must be present",
	)

	for interpreter in ([]string{"/lib/ld-musl-x86_64.so.1", "/opt/custom-runtime/lib/a-longer-dynamic-linker-path.so"}) {
		custom_image, custom_error := link_files([][]byte{main}, {}, []Shared_Library{shared}, "_start", context.allocator, interpreter)
		if !testing.expect(t, custom_error == nil, "custom interpreter image must link") { continue }
		defer delete(custom_image)
		file_header, header_ok := read_pod(custom_image, 0, elf.File_Header)
		if !testing.expect(t, header_ok, "custom interpreter image has an ELF header") { continue }
		found := false
		for index in 0 ..< int(file_header.e_phnum) {
			header, program_ok := read_pod(custom_image, int(file_header.e_phoff) + index * size_of(elf.Program_Header), elf.Program_Header)
			if !testing.expect(t, program_ok, "program header must be readable") { break }
			if u32(header.p_type) != elf.PT_INTERP { continue }
			found = true
			offset, size := int(header.p_offset), int(header.p_filesz)
			if !testing.expect(
				t,
				size == len(interpreter) + 1 && offset >= 0 && offset <= len(custom_image) - size,
				"PT_INTERP size follows the supplied path",
			) { break }
			testing.expect_value(t, string(custom_image[offset:offset + size - 1]), interpreter)
			testing.expect_value(t, custom_image[offset + size - 1], byte(0))
		}
		testing.expect(t, found, "shared-library image has PT_INTERP")
	}

	local := clang_object(t, directory, "local", "int value = 7;\nint load_value(void) { return value; }\n", {"-O2", "-fPIC"})
	local_start := clang_object(
		t,
		directory,
		"local_start",
		"extern int load_value(void);\nvoid _start(void) { long code = load_value(); __asm__ volatile(\"mov %0, %%rdi; mov $60, %%rax; syscall\" : : \"r\"(code) : \"rax\", \"rdi\"); }\n",
		{},
	)
	defer delete(local)
	defer delete(local_start)
	relaxed, relaxed_err := link_files([][]byte{local, local_start}, {}, {}, "_start", context.allocator, "/__odinc_unused_dynamic_linker__")
	testing.expect(t, relaxed_err == nil, "relaxed program must link")
	defer delete(relaxed)
	run_executable_expect_exit(t, relaxed, 7)
	relaxed_path, relaxed_path_err := filepath.join({directory, "relaxed"}, context.temp_allocator)
	testing.expect(t, relaxed_path_err == nil && os.write_entire_file(relaxed_path, relaxed) == nil, "relaxed image must be written")
	disassembly := run_command_capture(t, directory, "objdump.txt", []string{"llvm-objdump", "-d", relaxed_path})
	testing.expect(t, strings.contains(disassembly, "lea"), "REX_GOTPCRELX must relax to lea")
}
