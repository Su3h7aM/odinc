package types

// Reg_Class is the System V AMD64 eightbyte class (psABI 3.2.3). Odin has no
// x87 source type, so X87, X87_Up and Complex_X87 only take part in merging.
Reg_Class :: enum u8 {
	No_Class,
	Integer,
	SSE,
	SSE_Up,
	X87,
	X87_Up,
	Complex_X87,
	Memory,
}

MAX_CLASS_EIGHTBYTES :: 8

// Classification holds one class per eightbyte. count is 0 for zero-sized types.
Classification :: struct {
	classes: [MAX_CLASS_EIGHTBYTES]Reg_Class,
	count:   u8,
}

// classify reproduces lbAbiAmd64SysV::classify of the official compiler. Types
// made only of scalars, arrays and plain structs are walked from the Odin
// type; anything else (tagged unions, maps, complex numbers, #packed and #soa
// structs, SIMD vectors, ...) is walked as the compiler's lowered LLVM type,
// where padding is INTEGER and a #raw_union is one opaque integer blob.
// Register counting and argument planning are not part of this procedure.
classify :: proc(store: ^Store, id: Type_Id, config := DEFAULT_LAYOUT) -> (result: Classification, err: Layout_Error) {
	err = validate_layout(store, id)
	if err != .None {
		reset_layout_states(store)
		return {}, err
	}
	root := resolve_named(store, id)
	size, _ := layout_internal(store, root, config, 0)
	words := (size + 7) / 8
	if words == 0 { return result, .None }
	is_vector := get(store, root).kind == .Simd_Vector
	if words > MAX_CLASS_EIGHTBYTES || (words > 4 && !is_vector) {
		result.count = u8(min(words, MAX_CLASS_EIGHTBYTES))
		fill_memory(&result)
		return result, .None
	}
	result.count = u8(words)
	from_source := source_classifiable(store, root)
	classify_at(store, root, 0, &result, config, !from_source)
	fixup(&result)
	if from_source {
		for result.count > 0 && result.classes[result.count - 1] == .No_Class {
			result.count -= 1
		}
	}
	return result, .None
}

resolve_named :: proc(store: ^Store, type_id: Type_Id) -> Type_Id {
	id := type_id
	for get(store, id).kind == .Named { id = get(store, id).elem }
	return id
}

is_pointer_like :: proc(store: ^Store, id: Type_Id) -> bool {
	#partial switch get(store, resolve_named(store, id)).kind {
	case .Pointer, .Multi_Pointer, .CString, .CString16, .Procedure:
		return true
	}
	return false
}

source_classifiable :: proc(store: ^Store, id: Type_Id) -> bool {
	t := get(store, resolve_named(store, id))
	#partial switch t.kind {
	case .Bool, .Integer, .Rune, .Float:
		return t.endianness == .Native
	case .String, .CString, .Any, .Type_Id, .Raw_Pointer, .Pointer, .Multi_Pointer, .Procedure, .Enum, .Bit_Set, .Slice, .Dynamic_Array:
		return true
	case .Array, .Matrix:
		return source_classifiable(store, t.elem)
	case .Struct:
		if t.packed || t.soa != .None { return false }
		for field in t.fields {
			if !source_classifiable(store, field.type) { return false }
		}
		return true
	}
	return false
}

// The alignment LLVM gives the lowered form of a type, which differs from the
// Odin alignment for packed records, tagged unions and raw unions.
lowered_align :: proc(t: ^Type, odin_align: i64) -> i64 {
	#partial switch t.kind {
	case .Struct:
		if t.raw_union { return clamp(odin_align, 1, 8) }
		if t.packed { return 1 }
	case .Union:
		if t.union_form != .Maybe_Pointer { return 1 }
	}
	return odin_align
}

classify_at :: proc(store: ^Store, type_id: Type_Id, offset: i64, result: ^Classification, config: Layout_Config, lowered: bool) {
	id := resolve_named(store, type_id)
	t := get(store, id)
	size, alignment := layout_internal(store, id, config, 0)
	if lowered { alignment = lowered_align(t, alignment) }
	if alignment > 0 && offset % alignment != 0 {
		mark_memory(result, offset, size)
		return
	}
	#partial switch t.kind {
	case .Struct, .Tuple:
		if t.kind == .Struct && t.raw_union {
			if lowered {
				classify_integer_range(result, offset, size)
			} else {
				for field in t.fields { classify_at(store, field.type, offset, result, config, lowered) }
			}
			return
		}
		cursor := i64(0)
		for field, index in t.fields {
			field_start := field_offset_internal(store, id, index, config)
			if lowered && field_start > cursor { classify_integer_range(result, offset + cursor, field_start - cursor) }
			classify_at(store, field.type, offset + field_start, result, config, lowered)
			field_size, _ := layout_internal(store, field.type, config, 0)
			cursor = field_start + field_size
		}
		if lowered && size > cursor { classify_integer_range(result, offset + cursor, size - cursor) }
	case .Array, .Enumerated_Array:
		elem_size, _ := layout_internal(store, t.elem, config, 0)
		for i in 0 ..< t.count { classify_at(store, t.elem, offset + i * elem_size, result, config, lowered) }
	case .Fixed_Capacity_Array:
		elem_size, _ := layout_internal(store, t.elem, config, 0)
		for i in 0 ..< t.count { classify_at(store, t.elem, offset + i * elem_size, result, config, lowered) }
		classify_integer_range(result, offset + t.count * elem_size, size - t.count * elem_size)
	case .Matrix:
		elem_size, _ := layout_internal(store, t.elem, config, 0)
		for i in 0 ..< size / elem_size { classify_at(store, t.elem, offset + i * elem_size, result, config, lowered) }
	case .Union:
		classify_union(store, t, offset, size, result, config)
	case .Simd_Vector:
		elem_size, _ := layout_internal(store, t.elem, config, 0)
		if size < 8 {
			classify_integer_range(result, offset, size)
			return
		}
		for i in 0 ..< t.count {
			class := Reg_Class.SSE_Up
			if i == 0 { class = .SSE }
			unify(result, int((offset + i * elem_size) / 8), class)
		}
	case .Float:
		unify(result, int(offset / 8), .SSE)
	case .Complex, .Quaternion:
		component_count := i64(2) if t.kind == .Complex else 4
		for i in 0 ..< component_count {
			unify(result, int((offset + i * size / component_count) / 8), .SSE)
		}
	case:
		classify_integer_range(result, offset, size)
	}
}

// The lowered tagged union is a packed {block, tag, padding} record; the block
// is the sole distinct variant type when there is one, else an integer blob.
classify_union :: proc(store: ^Store, t: ^Type, offset, size: i64, result: ^Classification, config: Layout_Config) {
	if len(t.variants) == 0 { return }
	if t.union_form == .Maybe_Pointer {
		classify_at(store, t.variants[0], offset, result, config, true)
		return
	}
	info := union_layout_internal(store, t, config, 0)
	block_type := TYPE_NONE
	block_size := info.variant_block_size
	if len(t.variants) == 1 {
		block_type = t.variants[0]
	} else if info.variant_block_size != 0 {
		block_type = union_block_variant(store, t, info, config)
		if block_type == TYPE_NONE && union_all_pointers(store, t) && info.alignment == config.ptr_size {
			block_size = config.ptr_size
		}
	}
	if block_type != TYPE_NONE {
		block_size, _ = layout_internal(store, block_type, config, 0)
		classify_at(store, block_type, offset, result, config, true)
	} else {
		classify_integer_range(result, offset, block_size)
	}
	if block_size == 0 {
		block_size, _ = layout_internal(store, t.variants[0], config, 0)
	}
	tag_offset := offset + block_size
	if info.tag_size > 0 && tag_offset % info.tag_size != 0 {
		mark_memory(result, tag_offset, info.tag_size)
	} else {
		classify_integer_range(result, tag_offset, info.tag_size)
	}
	used := block_size + info.tag_size
	if size > used { classify_integer_range(result, offset + used, size - used) }
}

union_all_pointers :: proc(store: ^Store, t: ^Type) -> bool {
	for variant in t.variants {
		if !is_pointer_like(store, variant) { return false }
	}
	return true
}

// union_block_variant returns the variant type that stands for the whole block
// (all variants identical, or exactly one distinct non-empty type), else TYPE_NONE.
union_block_variant :: proc(store: ^Store, t: ^Type, info: Union_Layout, config: Layout_Config) -> Type_Id {
	if union_all_pointers(store, t) && info.alignment == config.ptr_size { return TYPE_NONE }
	all_identical := true
	for variant in t.variants[1:] {
		if variant != t.variants[0] { all_identical = false }
	}
	if all_identical { return t.variants[0] }
	first_distinct := TYPE_NONE
	for variant in t.variants {
		variant_size, _ := layout_internal(store, variant, config, 0)
		if variant_size == 0 { continue }
		if first_distinct == TYPE_NONE {
			first_distinct = variant
		} else if first_distinct != variant {
			return TYPE_NONE
		}
	}
	return first_distinct
}

classify_integer_range :: proc(result: ^Classification, offset, size: i64) {
	if size <= 0 { return }
	for index in offset / 8 ..= (offset + size - 1) / 8 { unify(result, int(index), .Integer) }
}

mark_memory :: proc(result: ^Classification, offset, size: i64) {
	for index in offset / 8 ..< (offset + size + 7) / 8 { unify(result, int(index), .Memory) }
}

fill_memory :: proc(result: ^Classification) {
	for i in 0 ..< int(result.count) { result.classes[i] = .Memory }
}

// unify merges a field class into an eightbyte (psABI 3.2.3 rules a-f). An
// SSE_Up never overrides an SSE head.
unify :: proc(result: ^Classification, index: int, incoming: Reg_Class) {
	if index < 0 || index >= int(result.count) { return }
	current := result.classes[index]
	switch {
	case current == incoming || incoming == .No_Class:
	case current == .No_Class:
		result.classes[index] = incoming
	case current == .Memory || incoming == .Memory:
		result.classes[index] = .Memory
	case current == .Integer || incoming == .Integer:
		result.classes[index] = .Integer
	case is_x87(current) || is_x87(incoming):
		result.classes[index] = .Memory
	case incoming == .SSE_Up && current == .SSE:
	case:
		result.classes[index] = incoming
	}
}

is_x87 :: proc(class: Reg_Class) -> bool {
	return class == .X87 || class == .X87_Up || class == .Complex_X87
}

// fixup is the psABI post-merger cleanup. Aggregates wider than two eightbytes
// stay in registers only as an SSE head followed by SSE_Up.
fixup :: proc(result: ^Classification) {
	count := int(result.count)
	if count > 2 {
		if result.classes[0] != .SSE {
			fill_memory(result)
			return
		}
		for i in 1 ..< count {
			if result.classes[i] != .SSE_Up {
				fill_memory(result)
				return
			}
		}
		return
	}
	for i in 0 ..< count {
		#partial switch result.classes[i] {
		case .Memory, .X87_Up:
			fill_memory(result)
			return
		case .SSE_Up:
			if i == 0 || (result.classes[i - 1] != .SSE && result.classes[i - 1] != .SSE_Up) {
				result.classes[i] = .SSE
			}
		}
	}
}
