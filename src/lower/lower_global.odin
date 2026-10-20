package lower

import "base:runtime"
import "core:math/big"
import "oc:check"
import "oc:ir"
import "oc:types"

// Encodes a constant initializer as little-endian bytes of a global of `size` bytes. `ok` is false when a value has
// no static image, including an address nested below the top level.
@(private)
global_constant_image :: proc(
	module: ^ir.Module,
	program: ^check.Checked_Program,
	id: check.Const_Id,
	size: u32,
	symbols: []ir.Symbol_Ref,
	relocs: []ir.Data_Reloc,
	allocator: runtime.Allocator,
) -> (
	bytes: []byte,
	out_relocs: []ir.Data_Reloc,
	ok: bool,
	err: runtime.Allocator_Error,
) {
	constant := check.constant(program, id)
	assert(constant != nil)
	bytes = make([]byte, size, allocator) or_return
	out_relocs = relocs
	#partial switch value in constant.value {
	case bool:
		if size > 0 { bytes[0] = u8(value) }
	case big.Int:
		integer := value
		negative, sign_error := big.int_is_negative(&integer, allocator)
		low, low_error := big.int_bitfield_extract(&integer, 0, 64, allocator)
		high, high_error := big.int_bitfield_extract(&integer, 64, 64, allocator)
		if sign_error != .None || low_error != .None || high_error != .None { return nil, nil, false, nil }
		words := [2]u64{u64(low), u64(high)}
		if negative {
			borrow: u64 = 1 if words[0] != 0 else 0
			words[0], words[1] = 0 - words[0], 0 - words[1] - borrow
		}
		write_little_endian(bytes, words[0], words[1])
	case check.Float_Value:
		scalar := ir.Value_Type.F64
		switch size {
		case 2:
			scalar = .F16
		case 4:
			scalar = .F32
		}
		bits, bits_ok := lower_float_bits(value, scalar)
		if !bits_ok { return nil, nil, false, nil }
		write_little_endian(bytes, bits, 0)
	case check.Pointer_Value:
		write_little_endian(bytes, u64(value), 0)
	case check.Nil_Value, check.Uninitialized_Value:
	case check.Aggregate_Value:
		relocations := make([dynamic]ir.Data_Reloc, allocator) or_return
		for reloc in relocs { append(&relocations, reloc) or_return }
		encoded := aggregate_constant_image(module, program, constant.type, value.elements, bytes, 0, &relocations, allocator) or_return
		if !encoded { return nil, nil, false, nil }
		out_relocs = relocations[:]
	case check.Address_Value:
		assert(int(value.symbol) > 0 && int(value.symbol) < len(symbols))
		out_relocs = make([]ir.Data_Reloc, len(relocs) + 1, allocator) or_return
		copy(out_relocs, relocs)
		out_relocs[len(relocs)] = {
			offset = 0,
			target = symbols[value.symbol],
			addend = value.addend,
		}
	case:
		return nil, nil, false, nil
	}
	return bytes, out_relocs, true, nil
}

// Writes each element of a constant aggregate at its field or element offset, relative to base. Nested aggregates
// recurse. Strings and C strings relocate their data pointers to module blobs; addresses stay unsupported.
@(private = "file")
aggregate_constant_image :: proc(
	module: ^ir.Module,
	program: ^check.Checked_Program,
	type: types.Type_Id,
	elements: []check.Const_Id,
	bytes: []byte,
	base: i64,
	relocations: ^[dynamic]ir.Data_Reloc,
	allocator: runtime.Allocator,
) -> (
	encoded: bool,
	err: runtime.Allocator_Error,
) {
	store := check.type_store(program)
	owner := types.resolve_named(store, type)
	descriptor := types.get(store, owner)
	for element, index in elements {
		if element == 0 { return false, nil }
		element_type: types.Type_Id
		offset: i64
		#partial switch descriptor.kind {
		case .Struct:
			element_type = descriptor.fields[index].type
			field_offset, offset_error := types.field_offset(store, owner, index)
			if offset_error != .None { return false, nil }
			offset = field_offset
		case .Array, .Enumerated_Array, .Simd_Vector:
			element_type = descriptor.elem
			element_size, _, element_error := types.layout(store, element_type)
			if element_error != .None { return false, nil }
			offset = i64(index) * element_size
		case .Matrix:
			// Constant elements are stored in physical order, so a flat index addresses its element directly.
			element_type = descriptor.elem
			matrix_element_size, _, matrix_element_error := types.layout(store, element_type)
			if matrix_element_error != .None { return false, nil }
			offset = i64(index) * matrix_element_size
		case:
			return false, nil
		}
		size, _, layout_error := types.layout(store, element_type)
		start := base + offset
		if layout_error != .None || start + size > i64(len(bytes)) { return false, nil }
		constant := check.constant(program, element)
		if aggregate, is_aggregate := constant.value.(check.Aggregate_Value); is_aggregate {
			encoded = aggregate_constant_image(module, program, element_type, aggregate.elements, bytes, start, relocations, allocator) or_return
			if !encoded { return false, nil }
			continue
		}
		if text, is_text := constant.value.(string); is_text {
			element_kind := types.get(store, types.resolve_named(store, element_type)).kind
			if element_kind == .String {
				blob, blob_error := global_string_blob(module, text)
				if blob_error != nil { return false, blob_error }
				write_scalar(bytes, start + 8, u64(len(text)), 8)
				append(relocations, ir.Data_Reloc{offset = u32(start), target = ir.Symbol_Ref{space = .Global, index = blob}}) or_return
			} else if element_kind == .CString {
				blob, blob_error := global_cstring_blob(module, text)
				if blob_error != nil { return false, blob_error }
				append(relocations, ir.Data_Reloc{offset = u32(start), target = ir.Symbol_Ref{space = .Global, index = blob}}) or_return
			} else {
				return false, nil
			}
			continue
		}
		if _, is_address := constant.value.(check.Address_Value); is_address { return false, nil }
		image, scalar_relocs, scalar_ok, image_error := global_constant_image(module, program, element, u32(size), nil, nil, allocator)
		if image_error != nil { return false, image_error }
		if !scalar_ok || len(scalar_relocs) != 0 { return false, nil }
		copy(bytes[start:], image)
	}
	return true, nil
}

@(private = "file")
write_little_endian :: proc(bytes: []byte, low, high: u64) {
	words := [2]u64{low, high}
	for index in 0 ..< min(len(bytes), 16) {
		bytes[index] = u8(words[index / 8] >> (8 * uint(index % 8)))
	}
}
