package check

import "oc:types"

// Default argument promotion of one C variadic tail value, as official c_vararg_promote_type
// (types.cpp:3635-3675). Endianness variants keep their byte order. Bit sets promote as their backing.
c_vararg_promoted_type :: proc(store: ^types.Store, type_id: types.Type_Id) -> types.Type_Id {
	core := types.core_type(store, type_id)
	descriptor := types.get(store, core)
	#partial switch descriptor.kind {
	case .Bit_Set:
		return c_vararg_promoted_type(store, descriptor.backing)
	case .Untyped_Integer:
		return types.default_type_of_untyped(store, core)
	case .Untyped_Float:
		return types.intern(store, types.Type{kind = .Float, count = 8})
	case .Untyped_Bool, .Bool:
		return types.intern(store, types.Type{kind = .Integer, name = "i32", count = 4, signed = true})
	case .Untyped_Nil:
		return types.intern(store, types.Type{kind = .Raw_Pointer})
	case .Float:
		if descriptor.count <= 4 {
			return types.intern(store, types.Type{kind = .Float, count = 8, endianness = descriptor.endianness})
		}
	case .Integer:
		if descriptor.count <= 2 {
			return types.intern(store, types.Type{kind = .Integer, name = "i32", count = 4, signed = true, endianness = descriptor.endianness})
		}
	}
	return type_id
}
