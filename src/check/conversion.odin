package check

import "core:slice"
import "oc:syntax"
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
	uintptr:     types.Type_Id,
	layout:      types.Layout_Config,
	field_flags: ^map[types.Type_Id][]syntax.Field_Flags,
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
	core_source := types.get(store, conversion_core_type(store, info.type))^
	core_target := types.get(store, conversion_core_type(store, target))^
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
	if kind == .Cast {
		assigned, assignment_diagnostic, assignment_error := check_conversion(pool, store, source, info, target, .Assignment, config)
		if assignment_error != nil { return {}, .None, assignment_error }
		if assignment_diagnostic == .None { return assigned, .None, nil }
		if core_source.kind == .Simd_Vector && core_target.kind == .Simd_Vector {
			if core_source.count != core_target.count { return {}, .Not_Castable, nil }
			element := Expression_Info {
				type  = core_source.elem,
				mode  = .Value,
				scope = info.scope,
				state = .Checked,
			}
			_, element_diagnostic, element_error := check_conversion(pool, store, source, element, core_target.elem, .Cast, config)
			if element_error != nil { return {}, .None, element_error }
			if element_diagnostic != .None { return {}, .Not_Castable, nil }
			return result, .None, nil
		}
		if core_target.kind == .Simd_Vector {
			scalar, scalar_diagnostic, scalar_error := check_conversion(pool, store, source, info, core_target.elem, .Cast, config)
			if scalar_error != nil { return {}, .None, scalar_error }
			if scalar_diagnostic != .None { return {}, .Not_Castable, nil }
			if scalar.info.mode == .Constant {
				lanes := make([]Const_Id, int(core_target.count), context.temp_allocator) or_return
				defer delete(lanes, context.temp_allocator)
				for &lane in lanes { lane = scalar.info.constant }
				result.info.mode = .Constant
				result.info.constant, err = constant_pool_intern_aggregate(pool, target, lanes)
			}
			return result, .None, err
		}
	}
	if kind == .Assignment && !untyped && dst.kind == .Any && src.kind != .Any {
		result.plan.kind = .Box
		return result, .None, nil
	}
	if kind == .Assignment && !untyped && dst.kind == .Union && info.type != target && conversion_union_variant(store, dst.variants, info.type) {
		result.plan.kind = .Union_Injection
		result.plan.source_type = info.type
		return result, .None, nil
	}
	if kind == .Assignment && untyped && src.kind != .Untyped_Nil && dst.kind == .Union {
		return conversion_untyped_union_variant(pool, store, source, info, target, config)
	}
	if kind == .Assignment && info.type != target && config.field_flags != nil {
		path := make([dynamic]Member_Step, 0, context.temp_allocator) or_return
		defer delete(path)
		found, path_error := conversion_subtype_path(store, config.field_flags^, info.type, target, &path)
		if path_error != nil { return {}, .None, path_error }
		if found {
			result.plan.kind = .Subtype
			result.plan.source_type = info.type
			result.plan.path, err = slice.clone(path[:], pool.allocator)
			if err != nil { return {}, .None, err }
			return result, .None, nil
		}
	}
	allowed := info.type == target
	if kind == .Assignment && untyped {
		allowed = conversion_integer(src.kind) && conversion_integer(dst.kind) || conversion_boolean(src.kind) && conversion_boolean(dst.kind)
		allowed ||= conversion_float(src.kind) && conversion_float(dst.kind)
		allowed ||= conversion_integer(src.kind) && conversion_float(dst.kind)
		allowed ||= conversion_float(src.kind) && conversion_integer(dst.kind)
		allowed ||= src.kind == .Untyped_Nil && conversion_nilable(dst)
		allowed ||= src.kind == .Untyped_String && (dst.kind == .String || dst.kind == .CString)
	}
	if kind == .Assignment && !untyped {
		allowed ||= info.mode == .Constant && src.kind == .String && dst.kind == .CString
		allowed ||= conversion_implicit_raw_pointer(store, info.type, target)
		allowed ||= conversion_implicit_pointer(store, info.type, target)
		allowed ||= simd_broadcast_allowed(dst, info.type)
	}
	if kind == .Cast {
		allowed ||= conversion_core_type(store, info.type) == conversion_core_type(store, target)
		allowed ||= info.mode == .Constant && core_source.kind == .String && core_target.kind == .CString
		allowed ||= conversion_boolean_or_integer(core_source.kind) && conversion_boolean_or_integer(core_target.kind)
		allowed ||= conversion_float(core_source.kind) && conversion_float(core_target.kind)
		allowed ||= conversion_integer(core_source.kind) && conversion_float(core_target.kind)
		allowed ||= conversion_float(core_source.kind) && conversion_integer(core_target.kind)
		allowed ||=
			(conversion_float(core_source.kind) || core_source.kind == .Complex || core_source.kind == .Untyped_Complex) &&
			(core_target.kind == .Complex || core_target.kind == .Quaternion)
		allowed ||= (core_source.kind == .Quaternion || core_source.kind == .Untyped_Quaternion) && core_target.kind == .Quaternion
		allowed ||= conversion_pointer(core_source.kind) && conversion_pointer(core_target.kind)
		allowed ||=
			core_source.kind == .CString && conversion_code_unit_pointer(store, core_target, 1) ||
			conversion_code_unit_pointer(store, core_source, 1) && core_target.kind == .CString
		allowed ||=
			core_source.kind == .CString16 && conversion_code_unit_pointer(store, core_target, 2) ||
			conversion_code_unit_pointer(store, core_source, 2) && core_target.kind == .CString16
		allowed ||= core_source.kind == .CString && core_target.kind == .String || core_source.kind == .CString16 && core_target.kind == .String16
		allowed ||= core_source.kind == .CString && core_target.kind == .Raw_Pointer || core_source.kind == .Raw_Pointer && core_target.kind == .CString
		allowed ||=
			conversion_code_unit_slice(store, core_source, 1) && core_target.kind == .String ||
			core_source.kind == .String && conversion_code_unit_slice(store, core_target, 1)
		allowed ||= conversion_code_unit_slice(store, core_source, 2) && core_target.kind == .String16
		allowed ||= info.type == config.uintptr && conversion_pointer(core_target.kind) || conversion_pointer(core_source.kind) && target == config.uintptr
		// Official check_is_castable_to: rawptr <-> procedure, both directions.
		allowed ||= core_source.kind == .Raw_Pointer && core_target.kind == .Procedure || core_source.kind == .Procedure && core_target.kind == .Raw_Pointer
	}
	if !allowed {
		return {}, .Not_Assignable if kind == .Assignment else .Not_Castable, nil
	}
	if dst.kind == .Simd_Vector {
		if info.mode != .Constant || !simd_broadcast_allowed(dst, info.type) { return result, .None, nil }
		lanes := make([]Const_Id, int(dst.count), context.temp_allocator) or_return
		defer delete(lanes, context.temp_allocator)
		for &lane in lanes { lane = info.constant }
		result.info.mode = .Constant
		result.info.constant, err = constant_pool_intern_aggregate(pool, target, lanes)
		return result, .None, err
	}
	if src.kind == .Untyped_Nil {
		nil_constant, nil_error := constant_pool_intern_nil(pool, target)
		if nil_error != nil { return {}, .None, nil_error }
		result.info.mode = .Constant
		result.info.constant = nil_constant
		return result, .None, nil
	}
	if info.mode == .Constant {
		if (src.kind == .Untyped_String || core_source.kind == .String && (kind == .Cast || dst.kind == .CString)) &&
		   (dst.kind == .String || dst.kind == .CString) {
			text, is_text := constant_pool_get(pool, info.constant).value.(string)
			if !is_text { return {}, .Invalid_Value, nil }
			constant, string_error := constant_pool_intern_string(pool, text, target)
			if string_error != nil { return {}, .None, string_error }
			result.info.mode = .Constant
			result.info.constant = constant
			result.plan.source = Operand(constant)
			return result, .None, nil
		}
		if !conversion_integer(core_target.kind) &&
		   !conversion_boolean(core_target.kind) &&
		   !conversion_float(core_target.kind) &&
		   core_target.kind != .Complex &&
		   core_target.kind != .Quaternion {
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

@(private = "file")
conversion_subtype_path :: proc(
	store: ^types.Store,
	flags: map[types.Type_Id][]syntax.Field_Flags,
	source, target: types.Type_Id,
	path: ^[dynamic]Member_Step,
	source_pointer := false,
	depth := 0,
) -> (
	found: bool,
	err: Constant_Error,
) {
	if depth >= len(store.types) { return false, nil }
	owner := types.resolve_named(store, source)
	descriptor := types.get(store, owner)
	indirect := descriptor.kind == .Pointer
	if indirect {
		owner = types.resolve_named(store, descriptor.elem)
		descriptor = types.get(store, owner)
	}
	if descriptor.kind != .Struct { return false, nil }
	field_flags := flags[owner]
	was_pointer := source_pointer || indirect
	target_descriptor := types.get(store, types.resolve_named(store, target))
	for field, index in descriptor.fields {
		if index >= len(field_flags) || (.Using not_in field_flags[index] && .Subtype not_in field_flags[index]) { continue }
		mark := len(path)
		append(path, Member_Step{type = owner, field_index = u32(index), indirect = indirect}) or_return
		if field.type == target || was_pointer && target_descriptor.kind == .Pointer && field.type == target_descriptor.elem {
			return true, nil
		}
		matched, nested_error := conversion_subtype_path(store, flags, field.type, target, path, was_pointer, depth + 1)
		if nested_error != nil { return false, nested_error }
		if matched { return true, nil }
		resize(path, mark)
	}
	return false, nil
}

conversion_base_type :: proc(store: ^types.Store, id: types.Type_Id) -> types.Type_Id {
	if id == types.TYPE_NONE { return types.TYPE_NONE }
	id := id
	for _ in 0 ..< len(store.types) {
		descriptor := types.get(store, id)
		if descriptor.kind != .Named { return id }
		id = descriptor.elem
	}
	return types.TYPE_POISON
}

// Matches official core_type: named, enum and bit_field types unwrap to their underlying type.
conversion_core_type :: proc(store: ^types.Store, id: types.Type_Id) -> types.Type_Id {
	id := id
	for _ in 0 ..< len(store.types) {
		descriptor := types.get(store, id)
		#partial switch descriptor.kind {
		case .Named:
			id = descriptor.elem
		case .Enum, .Bit_Field:
			id = descriptor.backing
		case:
			return id
		}
	}
	return types.TYPE_POISON
}

conversion_integer :: proc(kind: types.Kind) -> bool {
	return kind == .Integer || kind == .Rune || kind == .Untyped_Integer || kind == .Untyped_Rune
}

conversion_boolean :: proc(kind: types.Kind) -> bool {
	return kind == .Bool || kind == .Untyped_Bool
}

// Official check_is_castable_to: booleans and integers cast to each other.
conversion_boolean_or_integer :: proc(kind: types.Kind) -> bool {
	return conversion_boolean(kind) || conversion_integer(kind)
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


// Any ^T or [^]T converts implicitly to rawptr.
conversion_implicit_raw_pointer :: proc(store: ^types.Store, source, target: types.Type_Id) -> bool {
	if source == types.TYPE_NONE || target == types.TYPE_NONE { return false }
	src := types.get(store, conversion_base_type(store, source))^
	dst := types.get(store, conversion_base_type(store, target))^
	return dst.kind == .Raw_Pointer && (src.kind == .Pointer || src.kind == .Multi_Pointer)
}

// ^T and [^]T of one element type convert implicitly in either direction.
conversion_implicit_pointer :: proc(store: ^types.Store, source, target: types.Type_Id) -> bool {
	if source == types.TYPE_NONE || target == types.TYPE_NONE { return false }
	src := types.get(store, conversion_base_type(store, source))^
	dst := types.get(store, conversion_base_type(store, target))^
	if src.elem != dst.elem { return false }
	return src.kind == .Pointer && dst.kind == .Multi_Pointer || src.kind == .Multi_Pointer && dst.kind == .Pointer
}

// Matches official type_conversion_is_variant for a typed source: an identical variant, or a procedure variant whose base type is the source.
conversion_union_variant :: proc(store: ^types.Store, variants: []types.Type_Id, source: types.Type_Id) -> bool {
	for variant in variants {
		if variant == source { return true }
		base := conversion_base_type(store, variant)
		if base == source && types.get(store, base).kind == .Procedure { return true }
	}
	return false
}

conversion_untyped_union_variant :: proc(
	pool: ^Constant_Pool,
	store: ^types.Store,
	source: Operand,
	info: Expression_Info,
	target: types.Type_Id,
	config: Conversion_Config,
) -> (
	result: Conversion_Result,
	diagnostic: Conversion_Error,
	err: Constant_Error,
) {
	union_descriptor := types.get(store, conversion_base_type(store, target))^
	matched: Conversion_Result
	matches := 0
	default_type := types.default_type_of_untyped(store, info.type)
	default_matched: Conversion_Result
	default_matches := 0
	for variant in union_descriptor.variants {
		if types.get(store, conversion_base_type(store, variant)).kind == .Union { continue }
		candidate, candidate_diagnostic, candidate_err := check_conversion(pool, store, source, info, variant, .Assignment, config)
		if candidate_err != nil { return {}, .None, candidate_err }
		if candidate_diagnostic != .None { continue }
		matched = candidate
		matches += 1
		if conversion_base_type(store, variant) == default_type {
			default_matched = candidate
			default_matches += 1
		}
	}
	if matches != 1 {
		if default_matches != 1 { return {}, .Not_Assignable, nil }
		matched = default_matched
	}
	if matched.info.mode != .Constant { return Conversion_Result{reason = "Conversion_Untyped_Value"}, .Unsupported, nil }
	result.info = Expression_Info {
		type  = target,
		mode  = .Value,
		scope = info.scope,
		state = .Checked,
	}
	result.plan = Conversion_Plan {
		kind   = .Union_Injection,
		source = Operand(matched.info.constant),
		target = target,
	}
	return result, .None, nil
}

// Matches official type_has_nil: the types that accept a nil constant.
conversion_nilable :: proc(descriptor: types.Type) -> bool {
	if conversion_pointer(descriptor.kind) { return true }
	#partial switch descriptor.kind {
	case .Union:
		return descriptor.union_form != .No_Nil
	case .Struct:
		return descriptor.soa == .Slice || descriptor.soa == .Dynamic
	case .Soa_Pointer, .CString, .CString16, .Procedure, .Slice, .Dynamic_Array, .Map, .Enum, .Bit_Set, .Any, .Type_Id:
		return true
	}
	return false
}

// []u8 and string share one layout, so either converts to the other with a cast (not cstring).
// cstring and cstring16 convert to and from pointers of their code unit, as the official check_is_castable_to allows.
@(private = "file")
conversion_code_unit_pointer :: proc(store: ^types.Store, descriptor: types.Type, width: i64) -> bool {
	if descriptor.kind != .Pointer && descriptor.kind != .Multi_Pointer { return false }
	element := types.get(store, conversion_base_type(store, descriptor.elem))^
	return element.kind == .Integer && element.count == width && !element.signed
}

@(private = "file")
conversion_code_unit_slice :: proc(store: ^types.Store, descriptor: types.Type, width: i64) -> bool {
	if descriptor.kind != .Slice { return false }
	element := types.get(store, conversion_base_type(store, descriptor.elem))^
	return element.kind == .Integer && element.count == width && !element.signed
}

@(private = "file")
conversion_scalar :: proc(kind: types.Kind) -> bool {
	return conversion_integer(kind) || conversion_boolean(kind) || conversion_pointer(kind) || kind == .CString || kind == .Float
}
