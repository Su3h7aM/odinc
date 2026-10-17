package link

import "core:mem"

/*
	A static archive borrowed from the caller's bytes. `archive_take` returns
	a slice of those bytes. Free the maps with `archive_destroy`.
*/
Archive :: struct {
	data:      []byte,
	symbols:   map[string]int,
	taken:     map[int]bool,
	allocator: mem.Allocator,
}

/*
	Reads a System V archive symbol index (`/`, or `/SYM64/`). Members are
	extracted later, and only for undefined symbols.
*/
archive_read :: proc(data: []byte, allocator: mem.Allocator) -> (archive: Archive, err: Link_Error) {
	if len(data) < 8 || string(data[:8]) != "!<arch>\n" {
		return {}, Malformed_File{detail = "not an archive"}
	}
	archive.data = data
	archive.allocator = allocator
	archive.symbols = make(map[string]int, allocator = allocator)
	archive.taken = make(map[int]bool, allocator = allocator)
	defer if err != nil {
		archive_destroy(&archive)
	}

	position := 8
	for position + 60 <= len(data) {
		if position % 2 != 0 {
			position += 1
		}
		if position + 60 > len(data) {
			break
		}
		header := data[position:position + 60]
		if string(header[58:60]) != "`\n" {
			return {}, Malformed_File{detail = "bad archive header"}
		}
		size := parse_decimal(header[48:58])
		body := position + 60
		if body + size > len(data) {
			return {}, Malformed_File{detail = "truncated archive member"}
		}
		name := header[:16]
		if starts_with(name, "/ ") || starts_with(name, "/SYM64/ ") {
			wide := starts_with(name, "/SYM64/ ")
			read_archive_index(&archive, data[body:body + size], wide) or_return
		}
		position = body + size
	}
	return archive, nil
}

archive_destroy :: proc(archive: ^Archive) {
	if archive == nil {
		return
	}
	delete(archive.symbols)
	delete(archive.taken)
	archive^ = {}
}

/*
	Returns the object bytes for `name` the first time it is requested.
*/
archive_take :: proc(archive: ^Archive, name: string) -> (object: []byte, found: bool) {
	offset, ok := archive.symbols[name]
	if !ok || offset in archive.taken {
		return nil, false
	}
	if offset < 0 || offset + 60 > len(archive.data) {
		return nil, false
	}
	header := archive.data[offset:offset + 60]
	size := parse_decimal(header[48:58])
	body := offset + 60
	extra := 0
	if starts_with(header[:16], "#1/") {
		extra = parse_decimal(header[3:16])
	}
	if extra > size || body + size > len(archive.data) {
		return nil, false
	}
	archive.taken[offset] = true
	return archive.data[body + extra:body + size], true
}

read_archive_index :: proc(archive: ^Archive, body: []byte, wide: bool) -> Link_Error {
	width := 4
	if wide {
		width = 8
	}
	if len(body) < width {
		return Malformed_File{detail = "truncated archive index"}
	}
	count := read_be(body[:width])
	table := width + count * width
	if count < 0 || table > len(body) {
		return Malformed_File{detail = "truncated archive index"}
	}
	names := body[table:]
	cursor := 0
	for index in 0 ..< count {
		offset := read_be(body[width + index * width:][:width])
		end := cursor
		for end < len(names) && names[end] != 0 {
			end += 1
		}
		if end >= len(names) {
			return Malformed_File{detail = "truncated archive symbol"}
		}
		archive.symbols[string(names[cursor:end])] = offset
		cursor = end + 1
	}
	return nil
}

read_be :: proc(bytes: []byte) -> int {
	value := 0
	for byte in bytes {
		value = value * 256 + int(byte)
	}
	return value
}

parse_decimal :: proc(bytes: []byte) -> int {
	value := 0
	for byte in bytes {
		if byte < '0' || byte > '9' {
			continue
		}
		value = value * 10 + int(byte - '0')
	}
	return value
}

starts_with :: proc(bytes: []byte, prefix: string) -> bool {
	return len(bytes) >= len(prefix) && string(bytes[:len(prefix)]) == prefix
}
