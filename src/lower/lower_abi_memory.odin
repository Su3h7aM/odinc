package lower

import "oc:ir"

@(private)
abi_piece_size_valid :: proc(type: ir.Value_Type, size: i64) -> bool {
	width := piece_width(type)
	if width == 0 || size <= 0 { return false }
	return width <= size || (type >= .I8 && type <= .I64)
}

@(private)
abi_fragment_type :: proc(remaining: i64) -> ir.Value_Type {
	if remaining >= 4 { return .I32 }
	if remaining >= 2 { return .I16 }
	return .I8
}

@(private)
lower_load_abi_piece :: proc(state: ^Procedure_State, address: ir.Node_Id, type: ir.Value_Type, size: i64) -> ir.Node_Id {
	if piece_width(type) <= size { return lower_load_word(state, address, type) }
	function := state.job.function
	value := ir.const_int(function, type, 0)
	for offset := i64(0); offset < size; {
		fragment_type := abi_fragment_type(size - offset)
		fragment := lower_load_word(state, ir.ptr_offset(function, address, offset), fragment_type)
		fragment = ir.convert(function, .Zext, fragment, type)
		if offset != 0 { fragment = ir.binary(function, .Shl, fragment, ir.const_int(function, type, offset * 8)) }
		value = ir.binary(function, .Or, value, fragment)
		offset += piece_width(fragment_type)
	}
	return value
}

@(private)
lower_store_abi_piece :: proc(state: ^Procedure_State, address, value: ir.Node_Id, size: i64) {
	function := state.job.function
	type := function.nodes.type[value]
	if piece_width(type) <= size {
		lower_store_word(state, address, value)
		return
	}
	for offset := i64(0); offset < size; {
		fragment_type := abi_fragment_type(size - offset)
		fragment := value
		if offset != 0 { fragment = ir.binary(function, .Shr, fragment, ir.const_int(function, type, offset * 8)) }
		fragment = ir.convert(function, .Trunc, fragment, fragment_type)
		lower_store_word(state, ir.ptr_offset(function, address, offset), fragment)
		offset += piece_width(fragment_type)
	}
}
