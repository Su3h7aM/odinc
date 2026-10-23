package driver

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "oc:check"
import "oc:link"

// Multiarch directories are named after the target triplet (`/usr/lib/<arch>-<os>-<abi>`, Multiarch layout), which no spec fixes.
@(private = "file")
MULTIARCH_LIBRARY_PATTERN :: "/usr/lib/x86_64-linux-*"

Foreign_Library_Failed :: struct {
	path:   string,
	reason: string,
	code:   os.Error,
}

// Owned files of the program's foreign imports. Shared libraries keep their image bytes alive, since their symbol names alias them.
Foreign_Files :: struct {
	allocator:     runtime.Allocator,
	objects:       [dynamic][]byte,
	archives:      [dynamic][]byte,
	shared:        [dynamic]link.Shared_Library,
	shared_images: [dynamic][]byte,
}

foreign_files_destroy :: proc(foreign_files: ^Foreign_Files) {
	for object in foreign_files.objects {
		delete(object, foreign_files.allocator)
	}
	delete(foreign_files.objects)
	for archive in foreign_files.archives {
		delete(archive, foreign_files.allocator)
	}
	delete(foreign_files.archives)
	for &library in foreign_files.shared {
		link.shared_library_destroy(&library)
	}
	delete(foreign_files.shared)
	for image in foreign_files.shared_images {
		delete(image, foreign_files.allocator)
	}
	delete(foreign_files.shared_images)
	foreign_files^ = {}
}

has_object_magic :: proc(data: []byte) -> bool {
	return (len(data) >= 4 && string(data[:4]) == "\x7fELF") || (len(data) >= 8 && string(data[:8]) == "!<arch>\n")
}

// A library that bridges a real external library: a `system:` name, or a file outside the shipped base/ and core/ trees.
library_is_external :: proc(library_path: check.Library_Path, odin_root: string) -> bool {
	if library_path.system { return true }
	if !strings.has_prefix(library_path.name, odin_root) { return true }
	relative := library_path.name[len(odin_root):]
	return !strings.has_prefix(relative, "base/") && !strings.has_prefix(relative, "core/")
}

// Reads every file named by the program's foreign imports, each file once. On error the result is already destroyed.
load_foreign_files :: proc(
	program: ^check.Checked_Program,
	odin_root: string,
	allocator: runtime.Allocator,
) -> (
	foreign_files: Foreign_Files,
	err: Build_Error,
) {
	foreign_files.allocator = allocator
	defer if err != nil {
		foreign_files_destroy(&foreign_files)
	}
	foreign_files.objects = make([dynamic][]byte, allocator) or_return
	foreign_files.archives = make([dynamic][]byte, allocator) or_return
	foreign_files.shared = make([dynamic]link.Shared_Library, allocator) or_return
	foreign_files.shared_images = make([dynamic][]byte, allocator) or_return

	has_external_library := false
	loaded := make(map[string]bool, allocator = context.temp_allocator)
	for entity in program.entities {
		library, is_library := entity.data.(check.Library_Data)
		if !is_library || !library.used { continue }
		for library_path in library.paths {
			if library_is_external(library_path, odin_root) { has_external_library = true }
			file_path := library_path.name
			needed := library_path.name
			if library_path.system {
				found: bool
				file_path, found = find_system_library(library_path.name) or_return
				if !found {
					return foreign_files, Foreign_Library_Failed{path = library_path.name, reason = "is not in a standard system library directory"}
				}
				needed = filepath.base(file_path)
			}
			if err = load_foreign_path(&foreign_files, &loaded, file_path, needed, false, allocator); err != nil {
				return foreign_files, err
			}
		}
	}
	// libc and libm exist only to bridge external libraries: a program that imports only shipped files links neither.
	if !has_external_library { return foreign_files, nil }
	for name in ([]string{"c", "m"}) {
		// A missing default is not an error: its symbols stay undefined and fail at link time by name.
		library_path, found := find_system_library(name) or_return
		if !found { continue }
		start := len(foreign_files.shared)
		if err = load_foreign_path(&foreign_files, &loaded, library_path, filepath.base(library_path), false, allocator); err != nil {
			return foreign_files, err
		}
		for &library in foreign_files.shared[start:] { library.as_needed = true }
	}
	return foreign_files, nil
}

// Reads one file of a foreign import, once per path. A GNU ld script loads the files it names.
@(private = "file")
load_foreign_path :: proc(
	foreign_files: ^Foreign_Files,
	loaded: ^map[string]bool,
	file_path: string,
	needed: string,
	as_needed: bool,
	allocator: runtime.Allocator,
) -> Build_Error {
	if loaded[file_path] { return nil }
	loaded[file_path] = true

	data, read_err := os.read_entire_file(file_path, allocator)
	if read_err != nil {
		return Foreign_Library_Failed{path = file_path, reason = "cannot be read", code = read_err}
	}
	switch link.classify_file(data) {
	case .Relocatable:
		if _, append_err := append(&foreign_files.objects, data); append_err != nil {
			delete(data, allocator)
			return runtime.Allocator_Error.Out_Of_Memory
		}
	case .Archive:
		if _, append_err := append(&foreign_files.archives, data); append_err != nil {
			delete(data, allocator)
			return runtime.Allocator_Error.Out_Of_Memory
		}
	case .Shared:
		library_file, shared_err := link.shared_library_read(data, needed, allocator)
		if shared_err != nil {
			delete(data, allocator)
			return Foreign_Library_Failed{path = file_path, reason = "is not a readable shared object"}
		}
		if as_needed { library_file.as_needed = true }
		if _, append_err := append(&foreign_files.shared_images, data); append_err != nil {
			link.shared_library_destroy(&library_file)
			delete(data, allocator)
			return runtime.Allocator_Error.Out_Of_Memory
		}
		if _, append_err := append(&foreign_files.shared, library_file); append_err != nil {
			delete(pop(&foreign_files.shared_images), allocator)
			link.shared_library_destroy(&library_file)
			return runtime.Allocator_Error.Out_Of_Memory
		}
	case .Unknown:
		script_members, is_script, script_err := linker_script_paths(data, file_path)
		is_malformed_object := has_object_magic(data)
		delete(data, allocator)
		if script_err != nil { return script_err }
		if is_script {
			for member in script_members {
				load_foreign_path(foreign_files, loaded, member.path, filepath.base(member.path), as_needed || member.as_needed, allocator) or_return
			}
			return nil
		}
		// Assembly sources contribute no symbols: their externs stay undefined and fail at link time by name.
		if is_malformed_object || filepath.ext(file_path) != ".asm" {
			return Foreign_Library_Failed{path = file_path, reason = "is not an x86-64 ELF object, shared object, archive or linker script"}
		}
	}
	return nil
}

// One file named by a GNU ld script. Members wrapped in `AS_NEEDED` link only when referenced.
@(private = "file")
Script_Member :: struct {
	path:      string,
	as_needed: bool,
}

// Members named by a GNU ld script. `is_script` is false when the text does not start with GROUP, INPUT or OUTPUT_FORMAT.
@(private = "file")
linker_script_paths :: proc(data: []byte, script_path: string) -> (members: []Script_Member, is_script: bool, err: Build_Error) {
	uncommented := strings.builder_make(context.temp_allocator) or_return
	rest := string(data)
	for {
		start := strings.index(rest, "/*")
		if start < 0 {
			strings.write_string(&uncommented, rest)
			break
		}
		strings.write_string(&uncommented, rest[:start])
		end := strings.index(rest[start:], "*/")
		if end < 0 { break }
		rest = rest[start + end + 2:]
	}
	spaced, _ := strings.replace_all(strings.to_string(uncommented), "(", " ( ", context.temp_allocator)
	spaced, _ = strings.replace_all(spaced, ")", " ) ", context.temp_allocator)
	fields := strings.fields(spaced, context.temp_allocator) or_return
	if len(fields) == 0 || (fields[0] != "GROUP" && fields[0] != "INPUT" && fields[0] != "OUTPUT_FORMAT") {
		return nil, false, nil
	}

	script_dir := filepath.dir(script_path)
	collected := make([dynamic]Script_Member, context.temp_allocator) or_return
	in_as_needed := false
	skip_argument := false
	for field in fields {
		switch field {
		case "(", "GROUP", "INPUT":
			continue
		case ")":
			in_as_needed = false
			continue
		case "AS_NEEDED":
			in_as_needed = true
			continue
		case "OUTPUT_FORMAT":
			skip_argument = true
			continue
		}
		if skip_argument {
			skip_argument = false
			continue
		}
		switch {
		case strings.has_prefix(field, "-l"):
			library_file, found := find_system_library(field[2:]) or_return
			if !found {
				return nil, true, Foreign_Library_Failed{path = script_path, reason = "names a library that is not in a standard system library directory"}
			}
			append(&collected, Script_Member{path = library_file, as_needed = in_as_needed}) or_return
		case strings.has_prefix(field, "/"):
			append(&collected, Script_Member{path = field, as_needed = in_as_needed}) or_return
		case strings.contains(field, "."):
			append(&collected, Script_Member{path = filepath.join({script_dir, field}, context.temp_allocator) or_return, as_needed = in_as_needed}) or_return
		case:
			return nil, true, Foreign_Library_Failed{path = script_path, reason = "uses an unsupported linker script command"}
		}
	}
	return collected[:], true, nil
}

// Searched for `system:` libraries in this order: `/usr/local/lib`, the multiarch directories, then the FHS library directories.
@(private = "file")
system_library_directories :: proc() -> (directories: [dynamic]string, err: runtime.Allocator_Error) {
	directories = make([dynamic]string, context.temp_allocator) or_return
	append(&directories, "/usr/local/lib") or_return
	multiarch, _ := filepath.glob(MULTIARCH_LIBRARY_PATTERN, context.temp_allocator)
	append(&directories, ..multiarch) or_return
	append(&directories, "/usr/lib64", "/usr/lib", "/lib", "/lib64") or_return
	return directories, nil
}

// The first `lib<name>.so` or `lib<name>.a` in system_library_directories, in the temporary allocator.
@(private = "file")
find_system_library :: proc(name: string) -> (path: string, found: bool, err: runtime.Allocator_Error) {
	directories := system_library_directories() or_return
	for suffix in ([]string{".so", ".a"}) {
		file_name := strings.concatenate({"lib", name, suffix}, context.temp_allocator) or_return
		for directory in directories {
			candidate := filepath.join({directory, file_name}, context.temp_allocator) or_return
			if os.is_file(candidate) { return candidate, true, nil }
		}
	}
	return "", false, nil
}
