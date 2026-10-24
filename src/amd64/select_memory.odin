package amd64

import "oc:ir"

// Measured with rep stosb against a qword loop (cycles per call, 10M calls): the loop is faster
// through 256 bytes, the crossover with rep stosb is between 448 and 512 bytes.
FILL_LOOP_LIMIT :: 256

@(private)
Address_Parts :: struct {
	base:         ir.Node_Id,
	index:        ir.Node_Id,
	displacement: i32,
	scale:        u8,
}

// The address of an address node, computed once: its base, index and displacement.
// A node that does not fold is its own base.
@(private)
address_parts_of :: proc(selector: ^Selector, node: ir.Node_Id) -> Address_Parts {
	if !selector.address_ready[node] {
		selector.address_parts[node] = compute_address_parts(selector, node)
		selector.address_ready[node] = true
	}
	return selector.address_parts[node]
}

@(private)
compute_address_parts :: proc(selector: ^Selector, node: ir.Node_Id) -> Address_Parts {
	input := selector.input
	#partial switch input.nodes.kind[node] {
	case .Ptr_Offset:
		offset := input.nodes.data[node].int_value
		if offset >= i64(min(i32)) && offset <= i64(max(i32)) {
			base := address_parts_of(selector, ir.node_input(input, node, 0))
			displacement := i64(base.displacement) + offset
			if displacement >= i64(min(i32)) && displacement <= i64(max(i32)) {
				base.displacement = i32(displacement)
				return base
			}
		}
	case .Ptr_Index:
		stride := input.nodes.data[node].index
		if stride == 1 || stride == 2 || stride == 4 || stride == 8 {
			base := address_parts_of(selector, ir.node_input(input, node, 0))
			if base.index == ir.NODE_NONE && input.nodes.kind[base.base] != .Symbol_Addr {
				base.index, base.scale = ir.node_input(input, node, 1), u8(stride)
				return base
			}
		}
	}
	return Address_Parts{base = node}
}

// Whether an address node is folded into the memory operands of its users instead of
// being computed into a register.
@(private)
folds_into_operand :: proc(selector: ^Selector, node: ir.Node_Id) -> bool {
	return address_parts_of(selector, node).base != node
}

@(private)
select_address :: proc(selector: ^Selector, node: ir.Node_Id) -> (address: Memory_Ref, err: Select_Status) {
	input := selector.input
	parts := address_parts_of(selector, node)
	address.displacement = parts.displacement
	#partial switch input.nodes.kind[parts.base] {
	case .Stack_Slot:
		if input.nodes.data[parts.base].slot.align <= MAX_FRAME_ALIGNMENT {
			address.base = Frame_Object{.Slot, selector.slots[parts.base]}
		} else {
			address.base = select_value(selector, parts.base) or_return
		}
	case .Symbol_Addr:
		address.base = Symbol_Target {
			symbol = input.nodes.data[parts.base].symbol,
		}
	case:
		address.base = select_value(selector, parts.base) or_return
	}
	if parts.index != ir.NODE_NONE {
		address.index = select_value(selector, parts.index) or_return
		address.has_index, address.scale = true, parts.scale
	}
	return
}

@(private)
address_node :: proc(kind: ir.Node_Kind) -> bool {
	return kind == .Stack_Slot || kind == .Ptr_Offset || kind == .Ptr_Index
}

// Size of a constant-length copy or fill small enough to be emitted inline, when its
// address operands can take the displacement of every byte it touches.
@(private)
inline_copy_size :: proc(selector: ^Selector, node: ir.Node_Id) -> (size: u64, ok: bool) {
	input := selector.input
	inputs := ir.node_inputs(input, node)
	if input.nodes.kind[inputs[4]] != .Const_Int { return }
	size = u64(input.nodes.data[inputs[4]].int_value)
	if size > INLINE_COPY_LIMIT { return 0, false }
	address_count := 2 if input.nodes.kind[node] == .Mem_Copy else 1
	for operand in inputs[2:2 + address_count] {
		parts := address_parts_of(selector, operand)
		if i64(parts.displacement) + i64(size) > i64(max(i32)) { return 0, false }
	}
	return size, true
}

@(private)
is_address_operand :: proc(selector: ^Selector, node: ir.Node_Id, index: int) -> bool {
	input := selector.input
	#partial switch input.nodes.kind[node] {
	case .Load, .Store, .Load_Ordered, .Atomic_Rmw, .Atomic_Cas:
		return index == 2
	case .Mem_Copy, .Mem_Set:
		_, is_inline := inline_copy_size(selector, node)
		return is_inline && (index == 2 || index == 3 && input.nodes.kind[node] == .Mem_Copy)
	}
	return false
}

@(private)
require_address_value :: proc(selector: ^Selector, node: ir.Node_Id, pending: ^[dynamic]ir.Node_Id) -> Select_Status {
	if !address_node(selector.input.nodes.kind[node]) || selector.materialized[node] { return nil }
	selector.materialized[node] = true
	append(pending, node) or_return
	return nil
}

@(private)
require_address_parts :: proc(selector: ^Selector, node: ir.Node_Id, pending: ^[dynamic]ir.Node_Id) -> Select_Status {
	input := selector.input
	parts := address_parts_of(selector, node)
	if input.nodes.kind[parts.base] != .Stack_Slot || input.nodes.data[parts.base].slot.align > MAX_FRAME_ALIGNMENT {
		require_address_value(selector, parts.base, pending) or_return
	}
	if parts.index != ir.NODE_NONE { require_address_value(selector, parts.index, pending) or_return }
	return nil
}

@(private)
cover_address_inputs :: proc(selector: ^Selector, node: ir.Node_Id, pending: ^[dynamic]ir.Node_Id) -> Select_Status {
	input := selector.input
	if address_node(input.nodes.kind[node]) { return nil }
	for operand, index in ir.node_inputs(input, node) {
		if is_address_operand(selector, node, index) {
			require_address_parts(selector, operand, pending) or_return
		} else {
			require_address_value(selector, operand, pending) or_return
		}
	}
	return nil
}

// Marks the address nodes that some instruction consumes as a value; the others fold
// into the memory operands of their users and are never materialized.
@(private)
cover_addresses :: proc(selector: ^Selector) -> Select_Status {
	pending := make([dynamic]ir.Node_Id, selector.allocator)
	input := selector.input
	for block in selector.schedule.blocks {
		for node in block.nodes { cover_address_inputs(selector, node, &pending) or_return }
		exit := selector.schedule.cfg.exits[block.id]
		if exit != ir.NODE_NONE { cover_address_inputs(selector, exit, &pending) or_return }
	}
	for index := 0; index < len(pending); index += 1 {
		node := pending[index]
		if input.nodes.kind[node] == .Stack_Slot { continue }
		if folds_into_operand(selector, node) {
			require_address_parts(selector, node, &pending) or_return
		} else {
			for operand in ir.node_inputs(input, node) { require_address_value(selector, operand, &pending) or_return }
		}
	}
	return nil
}

@(private)
select_memory :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	kind := input.nodes.kind[node]
	inputs := ir.node_inputs(input, node)
	destination := selector.values[node]
	#partial switch kind {
	case .Stack_Slot:
		slot := input.nodes.data[node].slot
		if slot.align == 0 || slot.align & (slot.align - 1) != 0 { return select_failure(selector, .Unsupported_Alignment) }
		if slot.align > MAX_FRAME_ALIGNMENT {
			padding := slot.align - 1
			padded_size := u64(slot.size) + u64(padding)
			if padded_size > u64(max(i32)) { return select_failure(selector, .Unsupported_Alignment) }
			selector.slots[node] = add_frame_slot(output, u32(padded_size), MAX_FRAME_ALIGNMENT) or_return
			rounded := new_vreg(output, .Int) or_return
			emit(output, selector.block, .LEA, 8, rounded, Memory_Ref{base = Frame_Object{.Slot, selector.slots[node]}, displacement = i32(padding)}) or_return
			return emit(output, selector.block, .AND, 8, destination, rounded, Immediate(-i64(slot.align)))
		}
		selector.slots[node] = add_frame_slot(output, slot.size, slot.align) or_return
		if !selector.materialized[node] { return nil }
		return emit(output, selector.block, .LEA, 8, destination, Memory_Ref{base = Frame_Object{.Slot, selector.slots[node]}})
	case .Stack_Alloc:
		alignment := input.nodes.data[node].index
		if alignment > 16 { return select_failure(selector, .Unsupported_Alignment) }
		size := select_value(selector, inputs[1]) or_return
		rounded := new_vreg(output, .Int) or_return
		aligned := new_vreg(output, .Int) or_return
		stack := new_vreg(output, .Int) or_return
		adjusted := new_vreg(output, .Int) or_return
		emit(output, selector.block, .ADD, 8, rounded, size, Immediate(15)) or_return
		emit(output, selector.block, .AND, 8, aligned, rounded, Immediate(-16)) or_return
		emit(output, selector.block, .MOV, 8, stack, Physical_Register(Gpr.RSP)) or_return
		emit(output, selector.block, .SUB, 8, adjusted, stack, aligned) or_return
		emit(output, selector.block, .MOV, 8, Physical_Register(Gpr.RSP), adjusted) or_return
		return emit(output, selector.block, .ADD, 8, destination, adjusted, Immediate(output.outgoing_bytes))
	case .Ptr_Offset:
		if !selector.materialized[node] { return nil }
		if folds_into_operand(selector, node) {
			address := select_address(selector, node) or_return
			return emit(output, selector.block, .LEA, 8, destination, address)
		}
		base := select_value(selector, inputs[0]) or_return
		offset := input.nodes.data[node].int_value
		if offset >= i64(min(i32)) &&
		   offset <= i64(max(i32)) { return emit(output, selector.block, .LEA, 8, destination, Memory_Ref{base = base, displacement = i32(offset)}) }
		constant := new_vreg(output, .Int) or_return
		emit(output, selector.block, .MOVABS, 8, constant, Immediate(offset)) or_return
		return emit(output, selector.block, .ADD, 8, destination, base, constant)
	case .Ptr_Index:
		if !selector.materialized[node] { return nil }
		if folds_into_operand(selector, node) {
			address := select_address(selector, node) or_return
			return emit(output, selector.block, .LEA, 8, destination, address)
		}
		base := select_value(selector, inputs[0]) or_return
		index := select_value(selector, inputs[1]) or_return
		stride := input.nodes.data[node].index
		if stride == 1 ||
		   stride == 2 ||
		   stride == 4 ||
		   stride ==
			   8 { return emit(output, selector.block, .LEA, 8, destination, Memory_Ref{base = base, index = index, has_index = true, scale = u8(stride)}) }
		scale := new_vreg(output, .Int) or_return
		product := new_vreg(output, .Int) or_return
		emit(output, selector.block, .MOV, 4, scale, Immediate(stride)) or_return
		emit(output, selector.block, .IMUL, 8, product, index, scale) or_return
		return emit(output, selector.block, .LEA, 8, destination, Memory_Ref{base = base, index = product, has_index = true, scale = 1})
	case .Load:
		address := select_address(selector, inputs[2]) or_return
		if mnemonic, width, is_float := float_move(input.nodes.type[node]); is_float {
			return emit(output, selector.block, mnemonic, width, destination, address)
		}
		width := select_width(input.nodes.type[node])
		if width == 0 { return select_failure(selector) }
		return emit(output, selector.block, .MOVZX if width < 4 else .MOV, width, destination, address)
	case .Store:
		address := select_address(selector, inputs[2]) or_return
		if mnemonic, width, is_float := float_move(input.nodes.type[inputs[3]]); is_float {
			value := select_value(selector, inputs[3]) or_return
			emit(output, selector.block, mnemonic, width, address, value) or_return
		} else {
			value_width := select_width(input.nodes.type[inputs[3]])
			source := store_source(selector, inputs[3], address, value_width) or_return
			emit(output, selector.block, .MOV, value_width, address, source) or_return
		}
		if input.nodes.data[node].access.order == .Seq_Cst { return emit(output, selector.block, .MFENCE, 0) }
		return nil
	case .Mem_Copy, .Mem_Set:
		return select_copy_set(selector, node)
	}
	return select_failure(selector)
}

// A stored constant is an immediate, except at a RIP-relative address: verify_machine rejects
// a RIP-relative operand in an instruction that also has an immediate.
@(private)
store_source :: proc(selector: ^Selector, node: ir.Node_Id, address: Memory_Ref, width: u8) -> (source: Machine_Operand, err: Select_Status) {
	_, is_symbol := address.base.(Symbol_Target)
	if !is_symbol {
		if immediate, ok := immediate_operand(selector.input, node, width); ok { return immediate, nil }
	}
	value := select_value(selector, node) or_return
	return value, nil
}

@(private)
select_copy_set :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	inputs := ir.node_inputs(input, node)
	is_copy := input.nodes.kind[node] == .Mem_Copy
	if _, is_inline := inline_copy_size(selector, node); is_inline {
		return select_inline_copy_set(selector, node)
	}
	destination := select_value(selector, inputs[2]) or_return
	source := select_value(selector, inputs[3]) or_return
	count := select_value(selector, inputs[4]) or_return
	destination_copy := new_vreg(output, .Int) or_return
	source_copy := new_vreg(output, .Int) or_return
	count_copy := new_vreg(output, .Int) or_return
	emit_pseudo(output, selector.block, .Copy, destination_copy, destination) or_return
	emit_pseudo(output, selector.block, .Copy, source_copy, source) or_return
	emit_pseudo(output, selector.block, .Copy, count_copy, count) or_return
	if !is_copy {
		large := add_block(output) or_return
		small := add_block(output) or_return
		done := add_block(output) or_return
		emit(output, selector.block, .CMP, 8, count_copy, Immediate(FILL_LOOP_LIMIT)) or_return
		select_split(selector, .JA, large, small) or_return
		selector.block = large
		operands := [?]Machine_Operand {
			fixed(destination_copy, gpr(.RDI), .Use_Def),
			fixed(source_copy, gpr(.RAX), .Use),
			fixed(count_copy, gpr(.RCX), .Use_Def),
		}
		emit_instruction(output, large, Machine_Instruction{mnemonic = .STOSB, width = 1, rep = true, operands = operands[:]}) or_return
		select_jump(selector, done) or_return
		selector.block = small
		select_fill_loop(selector, destination_copy, count_copy, source_copy) or_return
		select_jump(selector, done) or_return
		selector.block = done
		return nil
	}
	forward := add_block(output) or_return
	backward := add_block(output) or_return
	done := add_block(output) or_return
	disjoint := add_block(output) or_return
	emit(output, selector.block, .CMP, 8, destination, source) or_return
	select_split(selector, .JBE, forward, disjoint) or_return
	selector.block = disjoint
	distance := new_vreg(output, .Int) or_return
	emit(output, disjoint, .SUB, 8, distance, destination, source) or_return
	emit(output, disjoint, .CMP, 8, distance, count) or_return
	select_split(selector, .JAE, forward, backward) or_return
	selector.block = backward
	back_source := new_vreg(output, .Int) or_return
	back_destination := new_vreg(output, .Int) or_return
	back_count := new_vreg(output, .Int) or_return
	emit(output, backward, .LEA, 8, back_source, Memory_Ref{base = source, index = count, has_index = true, scale = 1, displacement = -1}) or_return
	emit(output, backward, .LEA, 8, back_destination, Memory_Ref{base = destination, index = count, has_index = true, scale = 1, displacement = -1}) or_return
	emit_pseudo(output, backward, .Copy, back_count, count) or_return
	emit(output, backward, .STD, 0) or_return
	back_operands := [?]Machine_Operand {
		fixed(back_destination, gpr(.RDI), .Use_Def),
		fixed(back_source, gpr(.RSI), .Use_Def),
		fixed(back_count, gpr(.RCX), .Use_Def),
	}
	emit_instruction(output, backward, Machine_Instruction{mnemonic = .MOVSB, width = 1, rep = true, operands = back_operands[:]}) or_return
	emit(output, backward, .CLD, 0) or_return
	select_jump(selector, done) or_return
	selector.block = forward
	large := add_block(output) or_return
	small := add_block(output) or_return
	emit(output, forward, .CMP, 8, count_copy, Immediate(FILL_LOOP_LIMIT)) or_return
	select_split(selector, .JA, large, small) or_return
	selector.block = large
	operands := [?]Machine_Operand {
		fixed(destination_copy, gpr(.RDI), .Use_Def),
		fixed(source_copy, gpr(.RSI), .Use_Def),
		fixed(count_copy, gpr(.RCX), .Use_Def),
	}
	emit_instruction(output, large, Machine_Instruction{mnemonic = .MOVSB, width = 1, rep = true, operands = operands[:]}) or_return
	select_jump(selector, done) or_return
	selector.block = small
	select_copy_loop(selector, destination_copy, source_copy, count_copy) or_return
	select_jump(selector, done) or_return
	selector.block = done
	return nil
}

// Fills `count` bytes with the low byte of `fill` in qword stores, then in byte stores for the
// remainder. `destination` and `count` advance in place. Used below FILL_LOOP_LIMIT, where
// `rep stosb` pays a fixed startup cost that exceeds the loop.
@(private)
select_fill_loop :: proc(selector: ^Selector, destination, count, fill: Vreg) -> Select_Status {
	output := selector.output
	word := new_vreg(output, .Int) or_return
	pattern := new_vreg(output, .Int) or_return
	emit_pseudo(output, selector.block, .Copy, word, fill) or_return
	emit(output, selector.block, .AND, 8, word, word, Immediate(0xff)) or_return
	emit(output, selector.block, .MOVABS, 8, pattern, Immediate(0x0101_0101_0101_0101)) or_return
	emit(output, selector.block, .IMUL, 8, word, word, pattern) or_return
	word_check := add_block(output) or_return
	word_store := add_block(output) or_return
	tail_check := add_block(output) or_return
	tail_store := add_block(output) or_return
	finished := add_block(output) or_return
	select_jump(selector, word_check) or_return

	selector.block = word_check
	emit(output, word_check, .CMP, 8, count, Immediate(8)) or_return
	select_split(selector, .JB, tail_check, word_store) or_return

	selector.block = word_store
	emit(output, word_store, .MOV, 8, Memory_Ref{base = destination}, word) or_return
	emit(output, word_store, .ADD, 8, destination, destination, Immediate(8)) or_return
	emit(output, word_store, .SUB, 8, count, count, Immediate(8)) or_return
	select_jump(selector, word_check) or_return

	selector.block = tail_check
	emit(output, tail_check, .CMP, 8, count, Immediate(0)) or_return
	select_split(selector, .JE, finished, tail_store) or_return

	selector.block = tail_store
	emit(output, tail_store, .MOV, 1, Memory_Ref{base = destination}, word) or_return
	emit(output, tail_store, .ADD, 8, destination, destination, Immediate(1)) or_return
	emit(output, tail_store, .SUB, 8, count, count, Immediate(1)) or_return
	select_jump(selector, tail_check) or_return

	selector.block = finished
	return nil
}

// Copies forward in qword moves, then bytes for the remainder. Only a forward copy may use it: the
// source is read ahead of the destination, which overlapping memmove allows only when dst < src.
@(private)
select_copy_loop :: proc(selector: ^Selector, destination, source, count: Vreg) -> Select_Status {
	output := selector.output
	word := new_vreg(output, .Int) or_return
	word_check := add_block(output) or_return
	word_copy := add_block(output) or_return
	tail_check := add_block(output) or_return
	tail_copy := add_block(output) or_return
	finished := add_block(output) or_return
	select_jump(selector, word_check) or_return

	selector.block = word_check
	emit(output, word_check, .CMP, 8, count, Immediate(8)) or_return
	select_split(selector, .JB, tail_check, word_copy) or_return

	selector.block = word_copy
	emit(output, word_copy, .MOV, 8, word, Memory_Ref{base = source}) or_return
	emit(output, word_copy, .MOV, 8, Memory_Ref{base = destination}, word) or_return
	emit(output, word_copy, .ADD, 8, destination, destination, Immediate(8)) or_return
	emit(output, word_copy, .ADD, 8, source, source, Immediate(8)) or_return
	emit(output, word_copy, .SUB, 8, count, count, Immediate(8)) or_return
	select_jump(selector, word_check) or_return

	selector.block = tail_check
	emit(output, tail_check, .CMP, 8, count, Immediate(0)) or_return
	select_split(selector, .JE, finished, tail_copy) or_return

	selector.block = tail_copy
	emit(output, tail_copy, .MOVZX, 1, word, Memory_Ref{base = source}) or_return
	emit(output, tail_copy, .MOV, 1, Memory_Ref{base = destination}, word) or_return
	emit(output, tail_copy, .ADD, 8, destination, destination, Immediate(1)) or_return
	emit(output, tail_copy, .ADD, 8, source, source, Immediate(1)) or_return
	emit(output, tail_copy, .SUB, 8, count, count, Immediate(1)) or_return
	select_jump(selector, tail_check) or_return

	selector.block = finished
	return nil
}

// Each chunk moves through one register. A copy loads its source bytes; a constant fill stores
// its byte replicated across each chunk, widest chunks first; a computed fill stores its byte
// one at a time.
@(private)
select_inline_copy_set :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	inputs := ir.node_inputs(input, node)
	is_copy := input.nodes.kind[node] == .Mem_Copy
	size, _ := inline_copy_size(selector, node)
	destination := select_address(selector, inputs[2]) or_return
	if !is_copy && input.nodes.kind[inputs[3]] == .Const_Int {
		byte_value := u64(u8(input.nodes.data[inputs[3]].int_value))
		return select_constant_fill(selector, destination, size, byte_value * 0x0101_0101_0101_0101)
	}
	source: Memory_Ref
	fill: Vreg
	if is_copy {
		source = select_address(selector, inputs[3]) or_return
	} else {
		fill = select_value(selector, inputs[3]) or_return
	}
	values: [INLINE_COPY_LIMIT]Vreg
	widths: [INLINE_COPY_LIMIT]u8
	positions: [INLINE_COPY_LIMIT]i32
	length := 0
	for position := u64(0); position < size; {
		width := u64(8)
		for width > size - position { width /= 2 }
		value := fill
		if is_copy {
			value = new_vreg(output, .Int) or_return
			load := source
			load.displacement += i32(position)
			emit(output, selector.block, .MOVZX if width < 4 else .MOV, u8(width), value, load) or_return
		} else {
			width = 1
		}
		values[length], widths[length], positions[length] = value, u8(width), i32(position)
		length += 1
		position += width
	}
	for index in 0 ..< length {
		store := destination
		store.displacement += positions[index]
		emit(output, selector.block, .MOV, widths[index], store, values[index]) or_return
	}
	return nil
}

// `pattern` holds the fill byte in all eight bytes; each chunk stores its low `width` bytes.
@(private)
select_constant_fill :: proc(selector: ^Selector, destination: Memory_Ref, size: u64, pattern: u64) -> Select_Status {
	output, block := selector.output, selector.block
	for position := u64(0); position < size; {
		width := u64(8)
		for width > size - position { width /= 2 }
		chunk := pattern if width == 8 else pattern & ((u64(1) << (width * 8)) - 1)
		value := new_vreg(output, .Int) or_return
		if width == 8 && !fits_immediate(i64(chunk), 8) {
			emit(output, block, .MOVABS, 8, value, Immediate(i64(chunk))) or_return
		} else {
			emit(output, block, .MOV, u8(width), value, Immediate(i64(chunk))) or_return
		}
		store := destination
		store.displacement += i32(position)
		emit(output, block, .MOV, u8(width), store, value) or_return
		position += width
	}
	return nil
}
