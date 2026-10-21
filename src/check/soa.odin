package check

import "oc:types"

// The component labels of an `#soa` array index, matching the official params_xyzw table (check_type.cpp).
soa_array_names :: [4]string{"x", "y", "z", "w"}

// The hidden length field an `#soa` slice carries after its field pointers.
soa_hidden_len :: "__$len"

// Builds the struct descriptor an `#soa[N]T` or `#soa[]T` type denotes: one spread field per element
// field, an array or multi-pointer of it, plus the hidden length field for slices. An element whose
// core is neither a struct nor an array of up to four members is invalid. Field slices are allocated
// on the checker arena and borrowed by the stored descriptor.
soa_struct :: proc(checker: ^Type_Checker, elem: types.Type_Id, count: i64, kind: types.Soa_Kind) -> (type: types.Type_Id, valid: bool) {
	store := checker.store
	core := types.get(store, types.core_type(store, elem))
	core_descriptor := core^
	#partial switch core_descriptor.kind {
	case .Struct:
	// A struct element spreads its own fields as the soa fields.
	case .Array:
		if core_descriptor.count < 1 || core_descriptor.count > 4 { return 0, false }
	// An array element spreads its members under the x/y/z/w labels.
	case:
		return 0, false
	}
	total := int(core_descriptor.count) if core_descriptor.kind == .Array else len(core_descriptor.fields)
	if kind != .Fixed { total += 1 }
	names := soa_array_names
	fields := make([]types.Type_Field, total, checker.arena_allocator)
	position := 0
	for index in 0 ..< len(fields) {
		if index == len(fields) - 1 && kind != .Fixed {
			break
		}
		element_field: types.Type_Id
		name: string
		#partial switch core_descriptor.kind {
		case .Struct:
			element_field = core_descriptor.fields[index].type
			name = core_descriptor.fields[index].name
		case .Array:
			element_field = core_descriptor.elem
			name = names[index]
		}
		component: types.Type_Id
		if kind == .Fixed {
			component = types.intern(store, types.Type{kind = .Array, elem = element_field, count = count})
		} else {
			component = types.intern(store, types.Type{kind = .Multi_Pointer, elem = element_field})
		}
		fields[position] = types.Type_Field {
			name = name,
			type = component,
		}
		position += 1
	}
	if kind != .Fixed {
		length := types.sized_integer(store, 8, true)
		fields[total - 1] = types.Type_Field {
			name = soa_hidden_len,
			type = length,
		}
	}
	descriptor := types.Type {
		kind     = .Struct,
		fields   = fields,
		soa      = kind,
		soa_elem = elem,
	}
	if kind == .Fixed {
		descriptor.count = count
	}
	return types.intern(store, descriptor), true
}

// The soa descriptor of a type that is an `#soa` struct, resolving named layers. Dynamic soa arrays
// read as none, since they are not lowered yet.
soa_descriptor :: proc(store: ^types.Store, type_id: types.Type_Id) -> (soa: types.Type_Id, descriptor: ^types.Type, ok: bool) {
	resolved := types.resolve_named(store, type_id)
	descriptor = types.get(store, resolved)
	if descriptor.kind != .Struct || descriptor.soa == .None || descriptor.soa == .Dynamic {
		return 0, nil, false
	}
	return resolved, descriptor, true
}
