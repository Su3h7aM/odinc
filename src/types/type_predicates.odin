package types

// Unwraps named, enum and bit field layers, as the official `core_type` does.
core_type :: proc(store: ^Store, type_id: Type_Id) -> Type_Id {
	id := type_id
	for {
		descriptor := get(store, id)
		#partial switch descriptor.kind {
		case .Named:
			id = descriptor.elem
		case .Enum, .Bit_Field:
			id = descriptor.backing
		case:
			return id
		}
	}
}

is_comparable :: proc(store: ^Store, type_id: Type_Id) -> bool {
	descriptor := get(store, resolve_named(store, type_id))
	#partial switch descriptor.kind {
	case .Enum, .Bit_Field:
		return is_comparable(store, descriptor.backing)
	case .Bool, .Integer, .Float, .Rune, .Complex, .Quaternion, .String, .String16, .CString, .CString16:
		return true
	case .Raw_Pointer, .Pointer, .Multi_Pointer, .Soa_Pointer, .Procedure, .Type_Id, .Bit_Set, .Simd_Vector:
		return true
	case .Array, .Enumerated_Array, .Matrix:
		return is_comparable(store, descriptor.elem)
	case .Struct:
		if descriptor.soa != .None { return false }
		if descriptor.raw_union { return is_simple_compare(store, type_id) }
		for field in descriptor.fields {
			if !is_comparable(store, field.type) { return false }
		}
		return true
	case .Union:
		for variant in descriptor.variants {
			if !is_comparable(store, variant) { return false }
		}
		return true
	}
	return false
}

is_ordered :: proc(store: ^Store, type_id: Type_Id) -> bool {
	descriptor := get(store, core_type(store, type_id))
	#partial switch descriptor.kind {
	case .Integer, .Float, .Rune, .String, .String16, .CString, .CString16:
		return true
	case .Raw_Pointer, .Pointer, .Multi_Pointer:
		return true
	}
	return false
}

is_ordered_numeric :: proc(store: ^Store, type_id: Type_Id) -> bool {
	descriptor := get(store, resolve_named(store, type_id))
	#partial switch descriptor.kind {
	case .Integer, .Float, .Rune:
		return true
	case .Enum:
		return is_ordered_numeric(store, descriptor.backing)
	}
	return false
}

is_simple_compare :: proc(store: ^Store, type_id: Type_Id) -> bool {
	descriptor := get(store, core_type(store, type_id))
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Rune, .Raw_Pointer, .Type_Id:
		return true
	case .Pointer, .Multi_Pointer, .Soa_Pointer, .Procedure, .Bit_Set:
		return true
	case .Array, .Enumerated_Array, .Matrix, .Simd_Vector:
		return is_simple_compare(store, descriptor.elem)
	case .Struct:
		for field in descriptor.fields {
			if !is_simple_compare(store, field.type) { return false }
		}
		return true
	case .Union:
		return len(descriptor.variants) == 1 && is_simple_compare(store, descriptor.variants[0])
	}
	return false
}

is_enumerated_array :: proc(store: ^Store, type_id: Type_Id) -> bool {
	return get(store, resolve_named(store, type_id)).kind == .Enumerated_Array
}
