package driver

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "oc:check"
import "oc:link"

// Searched for `system:` libraries in this order; each name tries `lib<name>.so` in every directory before `lib<name>.a`.
@(private = "file")
SYSTEM_LIBRARY_DIRECTORIES := []string{"/usr/local/lib", "/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib", "/lib", "/lib64"}

Foreign_Library_Failed :: struct {
	path:   string,
	reason: string,
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

// Reads every file named by the program's foreign imports, each file once. On error the result is already destroyed.
load_foreign_files :: proc(program: ^check.Checked_Program, allocator: runtime.Allocator) -> (foreign_files: Foreign_Files, err: Build_Error) {
	foreign_files.allocator = allocator
	defer if err != nil {
		foreign_files_destroy(&foreign_files)
	}
	foreign_files.objects = make([dynamic][]byte, allocator) or_return
	foreign_files.archives = make([dynamic][]byte, allocator) or_return
	foreign_files.shared = make([dynamic]link.Shared_Library, allocator) or_return
	foreign_files.shared_images = make([dynamic][]byte, allocator) or_return

	loaded := make(map[string]bool, allocator = context.temp_allocator)
	for entity in program.entities {
		library, is_library := entity.data.(check.Library_Data)
		if !is_library || !library.used { continue }
		for library_path in library.paths {
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
			if loaded[file_path] { continue }
			loaded[file_path] = true

			data, read_err := os.read_entire_file(file_path, allocator)
			if read_err != nil {
				return foreign_files, Foreign_Library_Failed{path = file_path, reason = "cannot be read"}
			}
			switch link.classify_file(data) {
			case .Relocatable:
				append(&foreign_files.objects, data) or_return
			case .Archive:
				append(&foreign_files.archives, data) or_return
			case .Shared:
				library_file, shared_err := link.shared_library_read(data, needed, allocator)
				if shared_err != nil {
					delete(data, allocator)
					return foreign_files, Foreign_Library_Failed{path = file_path, reason = "is not a readable shared object"}
				}
				append(&foreign_files.shared_images, data) or_return
				append(&foreign_files.shared, library_file) or_return
			case .Unknown:
				// Not an object format this linker reads (e.g. assembly source): it contributes no symbols,
				// so any extern it was meant to define stays undefined and fails at link time by name.
				is_malformed_object := has_object_magic(data)
				delete(data, allocator)
				if is_malformed_object {
					return foreign_files, Foreign_Library_Failed{path = file_path, reason = "is not an x86-64 ELF object, shared object or archive"}
				}
			}
		}
	}
	return foreign_files, nil
}

// The first `lib<name>.so` or `lib<name>.a` in SYSTEM_LIBRARY_DIRECTORIES, in the temporary allocator.
@(private = "file")
find_system_library :: proc(name: string) -> (path: string, found: bool, err: runtime.Allocator_Error) {
	for suffix in ([]string{".so", ".a"}) {
		file_name := strings.concatenate({"lib", name, suffix}, context.temp_allocator) or_return
		for directory in SYSTEM_LIBRARY_DIRECTORIES {
			candidate := filepath.join({directory, file_name}, context.temp_allocator) or_return
			if os.is_file(candidate) { return candidate, true, nil }
		}
	}
	return "", false, nil
}
