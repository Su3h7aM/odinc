package link

import "core:mem"
import "oc:elf"

File_Kind :: enum u8 {
	Unknown,
	Relocatable,
	Archive,
	Shared,
}

// Classified by content, never by name: `libfoo.so.1` is a shared object like `libfoo.so`.
classify_file :: proc(data: []byte) -> File_Kind {
	if len(data) >= 8 && string(data[:8]) == "!<arch>\n" { return .Archive }
	header, ok := read_pod(data, 0, elf.File_Header)
	if !ok || string(header.ident[:4]) != elf.ELF_MAGIC || header.e_machine != .EM_X86_64 { return .Unknown }
	#partial switch header.e_type {
	case .ET_REL:
		return .Relocatable
	case .ET_DYN:
		return .Shared
	}
	return .Unknown
}

/*
	Links relocatable objects, lazily extracted archive members, and shared
	libraries. `needed` of a shared file is the `DT_NEEDED` string, the
	library's `DT_SONAME` when it has one. The image is owned by the caller.
*/
link_files :: proc(
	objects: [][]byte,
	archives: [][]byte,
	shared: []Shared_Library,
	entry: string,
	allocator: mem.Allocator,
) -> (
	image: []byte,
	err: Link_Error,
) {
	return link_inputs(nil, objects, archives, shared, entry, allocator)
}

/*
	Like `link_files`, with `initial` inputs that the caller keeps owning and
	that come before the objects. Archive members are extracted only for
	symbols that remain undefined.
*/
link_inputs :: proc(
	initial: []Input,
	objects: [][]byte,
	archives: [][]byte,
	shared: []Shared_Library,
	entry: string,
	allocator: mem.Allocator,
) -> (
	image: []byte,
	err: Link_Error,
) {
	parsed_archives := make([]Archive, len(archives), allocator) or_return
	defer {
		for &archive in parsed_archives {
			archive_destroy(&archive)
		}
		delete(parsed_archives, allocator)
	}
	for file, index in archives {
		parsed_archives[index] = archive_read(file, allocator) or_return
	}

	provided := make(map[string]bool, allocator = allocator)
	defer delete(provided)
	owner := make(map[string]int, allocator = allocator)
	defer delete(owner)
	for library, index in shared {
		for name in library.symbols {
			provided[name] = true
			if name not_in owner { owner[name] = index }
		}
	}

	inputs := make([dynamic]Input, 0, len(initial) + len(objects), allocator) or_return
	defer delete(inputs)
	append(&inputs, ..initial) or_return
	owned_start := len(inputs)
	defer {
		for &input in inputs[owned_start:] {
			input_destroy(&input, allocator)
		}
	}
	for file in objects {
		append(&inputs, read_object(file, allocator) or_return)
	}

	pulled := true
	defined := make(map[string]bool, allocator = allocator)
	defer delete(defined)
	for pulled {
		pulled = false
		clear(&defined)
		for input in inputs {
			for symbol in input.symbols {
				if symbol_defines(input, symbol) && symbol.binding != .Local && len(symbol.name) > 0 {
					defined[symbol.name] = true
				}
			}
		}
		for input in inputs {
			for symbol in input.symbols {
				if symbol.binding == .Local || len(symbol.name) == 0 || symbol.name in defined || symbol.name in provided {
					continue
				}
				if symbol_defines(input, symbol) {
					continue
				}
				for &archive in parsed_archives {
					member, found := archive_take(&archive, symbol.name)
					if !found {
						continue
					}
					append(&inputs, read_object(member, allocator) or_return)
					pulled = true
					break
				}
			}
		}
	}

	used := make([]bool, len(shared), allocator) or_return
	defer delete(used, allocator)
	for input in inputs {
		for symbol in input.symbols {
			if symbol.binding == .Local || len(symbol.name) == 0 || symbol.name in defined { continue }
			if index, is_provided := owner[symbol.name]; is_provided { used[index] = true }
		}
	}
	needed := make([dynamic]string, 0, len(shared), allocator) or_return
	defer delete(needed)
	for library, index in shared {
		if !library.as_needed || used[index] { append(&needed, library.needed) or_return }
	}
	return link_with(inputs[:], needed[:], provided, entry, allocator)
}
