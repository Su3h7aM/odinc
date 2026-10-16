package ir

INTERP_MEMORY_BASE :: u64(0x10000)

// Globals, then thread-local globals (one block), then blobs of `fn`, then stack slots, all from `INTERP_MEMORY_BASE`.
// Returns the memory size.
interp_layout :: proc(s: ^Interp_State) -> int {
	cursor: u64
	for global, index in s.module.globals {
		if !global.tls {
			s.global_addresses[index] = interp_bump(&cursor, u64(global.size), u64(global.align))
		}
	}
	for global, index in s.module.globals {
		if global.tls {
			s.global_addresses[index] = interp_bump(&cursor, u64(global.size), u64(global.align))
		}
	}
	for blob, index in s.fn.blobs {
		s.blob_addresses[index] = interp_bump(&cursor, u64(len(blob.bytes)), u64(blob.align))
	}
	for id in 1 ..< len(s.fn.nodes) {
		if s.fn.nodes.kind[id] == .Stack_Slot {
			slot := node_slot(s.fn, Node_Id(id))
			s.slot_addresses[id] = interp_bump(&cursor, u64(slot.size), u64(slot.align))
		}
	}
	return int(cursor)
}

// Copies the bytes of every global and blob of `fn` and resolves their relocations.
interp_initialize :: proc(s: ^Interp_State) -> bool {
	for global, index in s.module.globals {
		if !interp_write_object(s, s.global_addresses[index], global.bytes, global.size, global.relocs) {
			return false
		}
	}
	for blob, index in s.fn.blobs {
		if !interp_write_object(s, s.blob_addresses[index], blob.bytes, u32(len(blob.bytes)), blob.relocs) {
			return false
		}
	}
	return true
}

@(private = "file")
interp_bump :: proc(cursor: ^u64, size, align: u64) -> u64 {
	alignment := max(align, 1)
	cursor^ = (cursor^ + alignment - 1) / alignment * alignment
	address := INTERP_MEMORY_BASE + cursor^
	cursor^ += size
	return address
}

@(private = "file")
interp_write_object :: proc(s: ^Interp_State, address: u64, bytes: []byte, size: u32, relocs: []Data_Reloc) -> bool {
	offset := int(address - INTERP_MEMORY_BASE)
	copy(s.memory[offset:], bytes)
	for reloc in relocs {
		target, ok := interp_symbol_address(s, reloc.target)
		if !ok {
			interp_fail(s, .Unsupported, NODE_NONE)
			return false
		}
		if u64(reloc.offset) + 8 > u64(size) {
			interp_fail(s, .Unsupported, NODE_NONE)
			return false
		}
		at := offset + int(reloc.offset)
		interp_write(s.memory[at:at + 8], target + u64(reloc.addend))
	}
	return true
}

// Only globals and blobs have addresses here; functions and externs need calls (C3).
interp_symbol_address :: proc(s: ^Interp_State, symbol: Symbol_Ref) -> (u64, bool) {
	#partial switch symbol.space {
	case .Global:
		if int(symbol.index) < len(s.global_addresses) {
			return s.global_addresses[symbol.index], true
		}
	case .Local_Blob:
		if int(symbol.index) < len(s.blob_addresses) {
			return s.blob_addresses[symbol.index], true
		}
	}
	return 0, false
}

interp_address :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	#partial switch s.fn.nodes.kind[id] {
	case .Stack_Slot:
		return s.slot_addresses[id], true
	case .Symbol_Addr:
		address, found := interp_symbol_address(s, s.fn.nodes.data[id].symbol)
		if found {
			return address, true
		}
	case .Tls_Addr:
		symbol := s.fn.nodes.data[id].symbol
		if symbol.space == .Global && s.module.globals[symbol.index].tls {
			return interp_symbol_address(s, symbol)
		}
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}

// Sequential semantics: the memory state is a token, so every memory node runs in the order the schedule gives.
interp_memory_execute :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	fn := s.fn
	#partial switch fn.nodes.kind[id] {
	case .Load:
		return interp_load(s, id, fn.nodes.type[id])
	case .Load_Ordered:
		return interp_load(s, id, node_access(fn, id).value_type)
	case .Store:
		address := interp_operand(s, id, 2) or_return
		stored := interp_operand(s, id, 3) or_return
		return 0, interp_store(s, id, address, stored, fn.nodes.type[node_input(fn, id, 3)])
	case .Mem_Copy:
		destination := interp_operand(s, id, 2) or_return
		source := interp_operand(s, id, 3) or_return
		size := interp_operand(s, id, 4) or_return
		return 0, interp_copy(s, id, destination, source, size)
	case .Mem_Set:
		destination := interp_operand(s, id, 2) or_return
		byte_value := interp_operand(s, id, 3) or_return
		size := interp_operand(s, id, 4) or_return
		return 0, interp_set(s, id, destination, byte_value, size)
	case .Fence:
		return 0, true
	}
	interp_fail(s, .Unsupported, id)
	return 0, false
}

@(private = "file")
interp_access_width :: proc(type: Value_Type) -> (int, bool) {
	width := interp_width(type)
	if width < 8 {
		return 0, false
	}
	return width / 8, true
}

@(private = "file")
interp_load :: proc(s: ^Interp_State, id: Node_Id, type: Value_Type) -> (value: u64, ok: bool) {
	width, supported := interp_access_width(type)
	if !supported {
		interp_fail(s, .Unsupported, id)
		return 0, false
	}
	address := interp_operand(s, id, 2) or_return
	offset, in_range := interp_range(s, id, address, u64(width))
	if !in_range {
		return 0, false
	}
	return interp_read(s.memory[offset:offset + width]), true
}

@(private = "file")
interp_store :: proc(s: ^Interp_State, id: Node_Id, address, stored: u64, type: Value_Type) -> bool {
	width, supported := interp_access_width(type)
	if !supported {
		interp_fail(s, .Unsupported, id)
		return false
	}
	offset, in_range := interp_range(s, id, address, u64(width))
	if !in_range {
		return false
	}
	interp_write(s.memory[offset:offset + width], stored)
	return true
}

// Overlapping ranges copy as `memmove` does: `Mem_Copy` has memmove semantics (doc section 4).
@(private = "file")
interp_copy :: proc(s: ^Interp_State, id: Node_Id, destination, source, size: u64) -> bool {
	if size == 0 {
		return true
	}
	to, to_ok := interp_range(s, id, destination, size)
	if !to_ok {
		return false
	}
	from, from_ok := interp_range(s, id, source, size)
	if !from_ok {
		return false
	}
	count := int(size)
	if to < from {
		for i in 0 ..< count {
			s.memory[to + i] = s.memory[from + i]
		}
	} else if to > from {
		for i := count - 1; i >= 0; i -= 1 {
			s.memory[to + i] = s.memory[from + i]
		}
	}
	return true
}

@(private = "file")
interp_set :: proc(s: ^Interp_State, id: Node_Id, destination, byte_value, size: u64) -> bool {
	if size == 0 {
		return true
	}
	offset, in_range := interp_range(s, id, destination, size)
	if !in_range {
		return false
	}
	for i in 0 ..< int(size) {
		s.memory[offset + i] = u8(byte_value)
	}
	return true
}

// A null or out-of-range access is a `Fault` carrying the address; alignment is not checked.
@(private = "file")
interp_range :: proc(s: ^Interp_State, id: Node_Id, address, size: u64) -> (int, bool) {
	memory_size := u64(len(s.memory))
	if address >= INTERP_MEMORY_BASE && size <= memory_size && address - INTERP_MEMORY_BASE <= memory_size - size {
		return int(address - INTERP_MEMORY_BASE), true
	}
	s.result = Interp_Result {
		outcome = .Fault,
		value   = address,
		node    = id,
	}
	return 0, false
}

// Little-endian, as on x64.
@(private = "file")
interp_read :: proc(bytes: []u8) -> u64 {
	value: u64
	for i in 0 ..< len(bytes) {
		value |= u64(bytes[i]) << u64(8 * i)
	}
	return value
}

@(private = "file")
interp_write :: proc(bytes: []u8, value: u64) {
	for i in 0 ..< len(bytes) {
		bytes[i] = u8(value >> u64(8 * i))
	}
}
