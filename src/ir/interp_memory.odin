package ir

INTERP_MEMORY_BASE :: u64(0x10000)
INTERP_STACK_SIZE :: u64(64 * 1024)

// Globals, thread-local globals (one block), a distinct 8-byte cell per function and extern, blobs of
// every function, then the stack. Returns the memory size.
interp_layout :: proc(machine: ^Interp_Machine) -> int {
	cursor := INTERP_MEMORY_BASE
	for global, index in machine.module.globals {
		if !global.tls {
			machine.global_addresses[index] = interp_bump(&cursor, u64(global.size), u64(global.align))
		}
	}
	for global, index in machine.module.globals {
		if global.tls {
			machine.global_addresses[index] = interp_bump(&cursor, u64(global.size), u64(global.align))
		}
	}
	for &address in machine.function_addresses {
		address = interp_bump(&cursor, 8, 8)
	}
	for &address in machine.extern_addresses {
		address = interp_bump(&cursor, 8, 8)
	}
	for function, function_index in machine.module.functions {
		for blob, blob_index in function.blobs {
			machine.blob_addresses[function_index][blob_index] = interp_bump(&cursor, u64(len(blob.bytes)), u64(blob.align))
		}
	}
	machine.stack_top = interp_bump(&cursor, INTERP_STACK_SIZE, 16)
	machine.stack_end = cursor
	return int(cursor - INTERP_MEMORY_BASE)
}

// Copies the bytes of every global and blob and resolves their relocations.
interp_initialize :: proc(machine: ^Interp_Machine) -> bool {
	for global, index in machine.module.globals {
		if !interp_write_object(machine, 0, machine.global_addresses[index], global.bytes, global.size, global.relocs) {
			return false
		}
	}
	for function, function_index in machine.module.functions {
		for blob, blob_index in function.blobs {
			address := machine.blob_addresses[function_index][blob_index]
			if !interp_write_object(machine, u32(function_index), address, blob.bytes, u32(len(blob.bytes)), blob.relocs) {
				return false
			}
		}
	}
	return true
}

@(private = "file")
interp_bump :: proc(cursor: ^u64, size, align: u64) -> u64 {
	address := interp_align(cursor^, align)
	cursor^ = address + size
	return address
}

@(private = "file")
interp_align :: proc(value, align: u64) -> u64 {
	alignment := max(align, 1)
	return (value + alignment - 1) / alignment * alignment
}

// Allocates from the stack of the running frames; each frame gives its allocations back on return.
interp_stack_alloc :: proc(machine: ^Interp_Machine, size, align: u64) -> (u64, bool) {
	address := interp_align(machine.stack_top, align)
	if address > machine.stack_end || size > machine.stack_end - address {
		return 0, false
	}
	machine.stack_top = address + size
	return address, true
}

@(private = "file")
interp_write_object :: proc(machine: ^Interp_Machine, owner: u32, address: u64, bytes: []byte, size: u32, relocs: []Data_Reloc) -> bool {
	offset := int(address - INTERP_MEMORY_BASE)
	copy(machine.memory[offset:], bytes)
	for reloc in relocs {
		target, ok := interp_symbol_address(machine, owner, reloc.target)
		if !ok || u64(reloc.offset) + 8 > u64(size) {
			return false
		}
		at := offset + int(reloc.offset)
		interp_write(machine.memory[at:at + 8], target + u64(reloc.addend))
	}
	return true
}

// `Local_Blob` resolves within the blobs of function `owner`.
interp_symbol_address :: proc(machine: ^Interp_Machine, owner: u32, symbol: Symbol_Ref) -> (u64, bool) {
	#partial switch symbol.space {
	case .Global:
		if int(symbol.index) < len(machine.global_addresses) {
			return machine.global_addresses[symbol.index], true
		}
	case .Function:
		if int(symbol.index) < len(machine.function_addresses) {
			return machine.function_addresses[symbol.index], true
		}
	case .Extern:
		if int(symbol.index) < len(machine.extern_addresses) {
			return machine.extern_addresses[symbol.index], true
		}
	case .Local_Blob:
		blobs := machine.blob_addresses[owner]
		if int(symbol.index) < len(blobs) {
			return blobs[symbol.index], true
		}
	}
	return 0, false
}

interp_address :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	#partial switch s.fn.nodes.kind[id] {
	case .Stack_Slot:
		return s.slot_addresses[id], true
	case .Symbol_Addr:
		address, found := interp_symbol_address(s.machine, s.function_index, s.fn.nodes.data[id].symbol)
		if found {
			return address, true
		}
	case .Tls_Addr:
		symbol := s.fn.nodes.data[id].symbol
		if symbol.space == .Global && s.machine.module.globals[symbol.index].tls {
			return interp_symbol_address(s.machine, s.function_index, symbol)
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
	return interp_read(s.machine.memory[offset:offset + width]), true
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
	interp_write(s.machine.memory[offset:offset + width], stored)
	return true
}

// Overlapping ranges copy as `memmove` does: `Mem_Copy` has memmove semantics (doc section 4).
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
	memory := s.machine.memory
	count := int(size)
	if to < from {
		for i in 0 ..< count {
			memory[to + i] = memory[from + i]
		}
	} else if to > from {
		for i := count - 1; i >= 0; i -= 1 {
			memory[to + i] = memory[from + i]
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
		s.machine.memory[offset + i] = u8(byte_value)
	}
	return true
}

// A null or out-of-range access is a `Fault` carrying the address; alignment is not checked.
interp_range :: proc(s: ^Interp_State, id: Node_Id, address, size: u64) -> (int, bool) {
	memory_size := u64(len(s.machine.memory))
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
