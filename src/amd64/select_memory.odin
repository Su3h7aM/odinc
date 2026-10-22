package amd64

import "oc:ir"

@(private)
select_address :: proc(selector: ^Selector, node: ir.Node_Id) -> (address: Memory_Ref, err: Select_Status) {
	input := selector.input
	#partial switch input.nodes.kind[node] {
	case .Stack_Slot:
		if input.nodes.data[node].slot.align <= MAX_FRAME_ALIGNMENT {
			return Memory_Ref{base = Frame_Object{.Slot, selector.slots[node]}}, nil
		}
	case .Symbol_Addr:
		return Memory_Ref{base = Symbol_Target{symbol = input.nodes.data[node].symbol}}, nil
	case .Ptr_Offset:
		offset := input.nodes.data[node].int_value
		if offset >= i64(min(i32)) && offset <= i64(max(i32)) {
			base := select_address(selector, ir.node_input(input, node, 0)) or_return
			displacement := i64(base.displacement) + offset
			if displacement >= i64(min(i32)) && displacement <= i64(max(i32)) {
				base.displacement = i32(displacement)
				return base, nil
			}
		}
	case .Ptr_Index:
		stride := input.nodes.data[node].index
		if stride == 1 || stride == 2 || stride == 4 || stride == 8 {
			base := select_address(selector, ir.node_input(input, node, 0)) or_return
			_, symbol := base.base.(Symbol_Target)
			if !base.has_index && !symbol {
				base.index = select_value(selector, ir.node_input(input, node, 1)) or_return
				base.has_index, base.scale = true, u8(stride)
				return base, nil
			}
		}
	}
	value := select_value(selector, node) or_return
	return Memory_Ref{base = value}, nil
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
		base := select_value(selector, inputs[0]) or_return
		offset := input.nodes.data[node].int_value
		if offset >= i64(min(i32)) &&
		   offset <= i64(max(i32)) { return emit(output, selector.block, .LEA, 8, destination, Memory_Ref{base = base, displacement = i32(offset)}) }
		constant := new_vreg(output, .Int) or_return
		emit(output, selector.block, .MOVABS, 8, constant, Immediate(offset)) or_return
		return emit(output, selector.block, .ADD, 8, destination, base, constant)
	case .Ptr_Index:
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
		value := select_value(selector, inputs[3]) or_return
		if mnemonic, width, is_float := float_move(input.nodes.type[inputs[3]]); is_float {
			emit(output, selector.block, mnemonic, width, address, value) or_return
		} else {
			emit(output, selector.block, .MOV, select_width(input.nodes.type[inputs[3]]), address, value) or_return
		}
		if input.nodes.data[node].access.order == .Seq_Cst { return emit(output, selector.block, .MFENCE, 0) }
		return nil
	case .Mem_Copy, .Mem_Set:
		return select_copy_set(selector, node)
	}
	return select_failure(selector)
}

@(private)
select_copy_set :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	inputs := ir.node_inputs(input, node)
	is_copy := input.nodes.kind[node] == .Mem_Copy
	destination := select_value(selector, inputs[2]) or_return
	source := select_value(selector, inputs[3]) or_return
	count := select_value(selector, inputs[4]) or_return
	if input.nodes.kind[inputs[4]] == .Const_Int {
		size := u64(input.nodes.data[inputs[4]].int_value)
		if size <= INLINE_COPY_LIMIT {
			values: [INLINE_COPY_LIMIT]Vreg
			widths: [INLINE_COPY_LIMIT]u8
			positions: [INLINE_COPY_LIMIT]i32
			length := 0
			for position := u64(0); position < size; {
				width := u64(8)
				for width > size - position { width /= 2 }
				value := source
				if is_copy {
					value = new_vreg(output, .Int) or_return
					emit(
						output,
						selector.block,
						.MOVZX if width < 4 else .MOV,
						u8(width),
						value,
						Memory_Ref{base = source, displacement = i32(position)},
					) or_return
				} else {
					width = 1
				}
				values[length], widths[length], positions[length] = value, u8(width), i32(position)
				length += 1
				position += width
			}
			for index in 0 ..< length {
				emit(output, selector.block, .MOV, widths[index], Memory_Ref{base = destination, displacement = positions[index]}, values[index]) or_return
			}
			return nil
		}
	}
	destination_copy := new_vreg(output, .Int) or_return
	source_copy := new_vreg(output, .Int) or_return
	count_copy := new_vreg(output, .Int) or_return
	emit_pseudo(output, selector.block, .Copy, destination_copy, destination) or_return
	emit_pseudo(output, selector.block, .Copy, source_copy, source) or_return
	emit_pseudo(output, selector.block, .Copy, count_copy, count) or_return
	if !is_copy {
		operands := [?]Machine_Operand {
			fixed(destination_copy, gpr(.RDI), .Use_Def),
			fixed(source_copy, gpr(.RAX), .Use),
			fixed(count_copy, gpr(.RCX), .Use_Def),
		}
		return emit_instruction(output, selector.block, Machine_Instruction{mnemonic = .STOSB, width = 1, rep = true, operands = operands[:]})
	}
	forward := add_block(output) or_return
	backward := add_block(output) or_return
	done := add_block(output) or_return
	emit(output, selector.block, .CMP, 8, destination, source) or_return
	select_split(selector, .JBE, forward, backward) or_return
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
	operands := [?]Machine_Operand {
		fixed(destination_copy, gpr(.RDI), .Use_Def),
		fixed(source_copy, gpr(.RSI), .Use_Def),
		fixed(count_copy, gpr(.RCX), .Use_Def),
	}
	emit_instruction(output, forward, Machine_Instruction{mnemonic = .MOVSB, width = 1, rep = true, operands = operands[:]}) or_return
	select_jump(selector, done) or_return
	selector.block = done
	return nil
}
