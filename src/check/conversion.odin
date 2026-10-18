package check

import "oc:types"

Conversion_Error :: enum u8 {
	None,
	Invalid_Value,
	Invalid_Type,
	Not_Assignable,
	Not_Castable,
	Untyped_Transmute,
	Size_Mismatch,
	Not_Representable,
	Unsupported,
}

// uintptr is a configured builtin identity, never inferred from its spelling or width.
Conversion_Config :: struct {
	uintptr: types.Type_Id,
	layout:  types.Layout_Config,
}

Conversion_Result :: struct {
	info:   Expression_Info,
	plan:   Conversion_Plan,
	reason: string,
}

// Returns facts and a plan for the caller to retain in the existing typed/plan tables.
// Source rows are unchanged. Constant copies belong to pool; the result owns no memory.
@(require_results)
check_conversion :: proc(
	pool: ^Constant_Pool,
	store: ^types.Store,
	source: Operand,
	info: Expression_Info,
	target: types.Type_Id,
	kind: Conversion_Kind,
	config: Conversion_Config,
) -> (
	result: Conversion_Result,
	diagnostic: Conversion_Error,
	err: Constant_Error,
) {
	if info.state == .Invalid || info.type == types.TYPE_POISON { return {}, .Invalid_Value, nil }
	#partial switch info.mode {
	case .Constant, .Value, .Immutable_Value, .Variable, .Context:
	case:
		return {}, .Invalid_Value, nil
	}
	if info.type == 0 || target <= types.TYPE_POISON || int(target) >= len(store.types) || int(info.type) >= len(store.types) {
		return {}, .Invalid_Type, nil
	}
	src := types.get(store, conversion_base_type(store, info.type))^
	dst := types.get(store, conversion_base_type(store, target))^
	untyped := conversion_untyped(src.kind)
	result.info = Expression_Info {
		type  = target,
		mode  = .Value,
		scope = info.scope,
		state = .Checked,
	}
	result.plan = Conversion_Plan {
		kind   = kind,
		source = source,
		target = target,
	}
	if kind == .Transmute {
		if untyped { return {}, .Untyped_Transmute, nil }
		if conversion_untyped(dst.kind) { return {}, .Invalid_Type, nil }
		size, _, source_error := types.layout(store, info.type, config.layout)
		target_size, _, target_error := types.layout(store, target, config.layout)
		if source_error != .None || target_error != .None { return {}, .Invalid_Type, nil }
		if size != target_size { return {}, .Size_Mismatch, nil }
		return result, .None, nil
	}
	if kind != .Assignment && kind != .Cast { return Conversion_Result{reason = "Conversion_Kind"}, .Unsupported, nil }
	if kind == .Assignment && !untyped && dst.kind == .Any && src.kind != .Any {
		result.plan.kind = .Box
		return result, .None, nil
	}
	allowed := info.type == target
	if kind == .Assignment && untyped {
		allowed = conversion_integer(src.kind) && conversion_integer(dst.kind) || conversion_boolean(src.kind) && conversion_boolean(dst.kind)
		allowed ||= conversion_float(src.kind) && conversion_float(dst.kind)
		allowed ||= conversion_integer(src.kind) && conversion_float(dst.kind)
		allowed ||= conversion_float(src.kind) && conversion_integer(dst.kind)
		allowed ||= src.kind == .Untyped_Nil && conversion_nilable(dst.kind)
	}
	if kind == .Assignment && !untyped {
		allowed ||= dst.kind == .Raw_Pointer && (src.kind == .Pointer || src.kind == .Multi_Pointer)
		allowed ||= dst.kind == .Pointer && src.kind == .Multi_Pointer && dst.elem == src.elem
		allowed ||= dst.kind == .Multi_Pointer && src.kind == .Pointer && dst.elem == src.elem
		allowed ||= simd_broadcast_allowed(dst, info.type)
	}
	if kind == .Cast {
		allowed ||= src.kind == .Enum && conversion_integer(dst.kind)
		allowed ||= conversion_integer(src.kind) && conversion_integer(dst.kind) || conversion_boolean(src.kind) && conversion_boolean(dst.kind)
		allowed ||= conversion_float(src.kind) && conversion_float(dst.kind)
		allowed ||= conversion_integer(src.kind) && conversion_float(dst.kind)
		allowed ||= conversion_float(src.kind) && conversion_integer(dst.kind)
		allowed ||= conversion_pointer(src.kind) && conversion_pointer(dst.kind)
		allowed ||= src.kind == .CString && conversion_code_unit_pointer(store, dst, 1) || conversion_code_unit_pointer(store, src, 1) && dst.kind == .CString
		allowed ||=
			src.kind == .CString16 && conversion_code_unit_pointer(store, dst, 2) || conversion_code_unit_pointer(store, src, 2) && dst.kind == .CString16
		allowed ||= src.kind == .CString && dst.kind == .Raw_Pointer || src.kind == .Raw_Pointer && dst.kind == .CString
		allowed ||= conversion_byte_slice(store, src) && dst.kind == .String || src.kind == .String && conversion_byte_slice(store, dst)
		allowed ||= info.type == config.uintptr && conversion_pointer(dst.kind) || conversion_pointer(src.kind) && target == config.uintptr
	}
	if !allowed {
		return {}, .Not_Assignable if kind == .Assignment else .Not_Castable, nil
	}
	if dst.kind == .Simd_Vector { return result, .None, nil }
	if src.kind == .Untyped_Nil {
		nil_constant, nil_error := constant_pool_intern_nil(pool, target)
		if nil_error != nil { return {}, .None, nil_error }
		result.info.mode = .Constant
		result.info.constant = nil_constant
		return result, .None, nil
	}
	if info.mode == .Constant {
		if !conversion_integer(dst.kind) && !conversion_boolean(dst.kind) && !conversion_float(dst.kind) {
			return Conversion_Result{reason = "Conversion_Constant_Target"}, .Unsupported, nil
		}
		constant, conversion_error := numeric_convert_constant(pool, store, info.constant, info.type, target)
		if conversion_error.kind == .Internal_Error { return {}, .None, Constant_Pool_Error.Invalid_Operand }
		if conversion_error.kind != .None { return {}, .Not_Representable, nil }
		result.info.mode = .Constant
		result.info.constant = constant
	}
	return result, .None, nil
}

conversion_base_type :: proc(store: ^types.Store, id: types.Type_Id) -> types.Type_Id {
	id := id
	for _ in 0 ..< len(store.types) {
		descriptor := types.get(store, id)
		if descriptor.kind != .Named { return id }
		id = descriptor.elem
	}
	return types.TYPE_POISON
}

conversion_integer :: proc(kind: types.Kind) -> bool {
	return kind == .Integer || kind == .Rune || kind == .Untyped_Integer || kind == .Untyped_Rune
}

conversion_boolean :: proc(kind: types.Kind) -> bool {
	return kind == .Bool || kind == .Untyped_Bool
}

conversion_float :: proc(kind: types.Kind) -> bool {
	return kind == .Float || kind == .Untyped_Float
}

conversion_untyped :: proc(kind: types.Kind) -> bool {
	return .Untyped_Bool <= kind && kind <= .Untyped_Nil
}

conversion_pointer :: proc(kind: types.Kind) -> bool {
	return kind == .Pointer || kind == .Multi_Pointer || kind == .Raw_Pointer
}

conversion_nilable :: proc(kind: types.Kind) -> bool {
	return conversion_pointer(kind) || kind == .CString || kind == .CString16 || kind == .Procedure
}

// []u8 and string share one layout, so either converts to the other with a cast (not cstring).
// cstring and cstring16 convert to and from pointers of their code unit, as the official check_is_castable_to allows.
@(private = "file")
conversion_code_unit_pointer :: proc(store: ^types.Store, descriptor: types.Type, width: i64) -> bool {
	if descriptor.kind != .Pointer && descriptor.kind != .Multi_Pointer { return false }
	element := types.get(store, conversion_base_type(store, descriptor.elem))^
	return element.kind == .Integer && element.count == width && !element.signed
}

// []u8 and string share one layout, so either converts to the other with a cast (not cstring).
@(private = "file")
conversion_byte_slice :: proc(store: ^types.Store, descriptor: types.Type) -> bool {
	if descriptor.kind != .Slice { return false }
	element := types.get(store, conversion_base_type(store, descriptor.elem))^
	return element.kind == .Integer && element.count == 1 && !element.signed
}

@(private = "file")
conversion_scalar :: proc(kind: types.Kind) -> bool {
	return conversion_integer(kind) || conversion_boolean(kind) || conversion_pointer(kind) || kind == .CString || kind == .Float
}
