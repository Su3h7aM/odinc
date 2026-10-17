package link

import "core:mem"

/*
	Links relocatable objects, lazily extracted archive members, and shared
	libraries. `needed` of a shared file is the `DT_NEEDED` string; an empty
	name uses the object's `DT_SONAME`. The image is owned by the caller.
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

	needed := make([]string, len(shared), allocator) or_return
	defer delete(needed, allocator)
	provided := make(map[string]bool, allocator = allocator)
	defer delete(provided)
	for library, index in shared {
		needed[index] = library.needed
		for name in library.symbols {
			provided[name] = true
		}
	}

	inputs := make([dynamic]Input, allocator) or_return
	defer {
		for &input in inputs {
			input_destroy(&input, allocator)
		}
		delete(inputs)
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

	return link_with(inputs[:], needed, provided, entry, allocator)
}
