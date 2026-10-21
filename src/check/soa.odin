package check

import "oc:types"

// The component labels of an `#soa` array index, matching the official params_xyzw table (check_type.cpp).
soa_array_names :: [4]string{"x", "y", "z", "w"}

// The hidden length field an `#soa` slice carries after its field pointers.
soa_hidden_len :: "__$len"

// The hidden capacity field an `#soa[dynamic]` array carries after its hidden length.
soa_hidden_cap :: "__$cap"

// Builds the struct descriptor an `#soa[N]T`, `#soa[]T` or `#soa[dynamic]T` type denotes: one spread
// field per element field, an array or multi-pointer of it, plus the hidden length field for slices
// and the hidden length, capacity and allocator fields for dynamic arrays, matching the official
// complete_soa_type layout (check_type.cpp). An element whose core is neither a struct nor an array
// of up to four members is invalid. Field slices are allocated on the checker arena and borrowed by
// the stored descriptor.
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
	field_count := len(core_descriptor.fields) if core_descriptor.kind == .Struct else int(core_descriptor.count)
	extra := 0
	if kind == .Slice { extra = 1 } else if kind == .Dynamic { extra = 3 }
	names := soa_array_names
	fields := make([]types.Type_Field, field_count + extra, checker.arena_allocator)
	for index in 0 ..< field_count {
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
		if kind == .Fixed {
			fields[index] = {
				name = name,
				type = types.intern(store, types.Type{kind = .Array, elem = element_field, count = count}),
			}
		} else {
			fields[index] = {
				name = name,
				type = types.intern(store, types.Type{kind = .Multi_Pointer, elem = element_field}),
			}
		}
	}
	if kind == .Slice || kind == .Dynamic {
		length := types.sized_integer(store, 8, true)
		fields[field_count] = types.Type_Field {
			name = soa_hidden_len,
			type = length,
		}
	}
	if kind == .Dynamic {
		capacity := types.sized_integer(store, 8, true)
		fields[field_count + 1] = types.Type_Field {
			name = soa_hidden_cap,
			type = capacity,
		}
		fields[field_count + 2] = types.Type_Field {
			name = "allocator",
			type = soa_allocator_type(checker),
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

// The allocator field type of an `#soa[dynamic]` array: the runtime Allocator when the runtime package
// is collected, otherwise a structural procedure/data pair with the same 16-byte size and 8-byte
// alignment, so layout queries stay byte-identical either way.
soa_allocator_type :: proc(checker: ^Type_Checker) -> types.Type_Id {
	if checker.resolver != nil && checker.collection != nil && checker.collection.runtime_scope != 0 {
		scopes := checker.resolver.scopes
		entity := scope_lookup_current(scopes, checker.collection.runtime_scope, "Allocator")
		if entity != 0 {
			if _, resolve_error := resolve_entity(checker.resolver, entity); resolve_error == nil {
				return entity_get(scopes, entity).type
			}
		}
	}
	procedure := types.intern(checker.store, types.Type{kind = .Procedure})
	data := types.intern(checker.store, types.Type{kind = .Raw_Pointer})
	fields := make([]types.Type_Field, 2, checker.arena_allocator)
	fields[0] = types.Type_Field {
		name = "procedure",
		type = procedure,
	}
	fields[1] = types.Type_Field {
		name = "data",
		type = data,
	}
	return types.intern(checker.store, types.Type{kind = .Struct, fields = fields})
}

// The soa descriptor of a type that is an `#soa` struct, resolving named layers.
soa_descriptor :: proc(store: ^types.Store, type_id: types.Type_Id) -> (soa: types.Type_Id, descriptor: ^types.Type, ok: bool) {
	resolved := types.resolve_named(store, type_id)
	descriptor = types.get(store, resolved)
	if descriptor.kind != .Struct || descriptor.soa == .None {
		return 0, nil, false
	}
	return resolved, descriptor, true
}
