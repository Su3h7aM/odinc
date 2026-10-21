package check

import "oc:syntax"
import "oc:types"

// Type predicates of base:intrinsics. Most answer with a constant bool; the base and core queries answer with a type.
// Semantics mirror refs/Odin-upstream/src/check_builtin.cpp (the simple-boolean table and the matrix row/column-major
// cases) over refs/Odin-upstream/src/types.cpp `is_type_*`, including the flag-based `type_is_string` (true for
// cstring, string16 and cstring16), the unwrapped `type_is_named` (true for every basic type), and the hard errors
// for non-type and non-matrix arguments.
@(private = "package")
expression_type_predicate :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	#partial switch kind {
	case .Type_Is_Subtype_Of, .Type_Is_Superset_Of, .Type_Is_Variant_Of:
		return expression_type_relation(checker, view, scope, node, kind, arguments, ellipsis)
	}
	if len(arguments) != 1 || ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operand := type_query_operand(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.mode != .Type { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	store := checker.type_checker.store
	#partial switch kind {
	case .Type_Base_Type:
		return Expression_Info{type = types.resolve_named(store, operand.type), mode = .Type, scope = scope, state = .Checked}, nil
	case .Type_Core_Type:
		return Expression_Info{type = types.core_type(store, operand.type), mode = .Type, scope = scope, state = .Checked}, nil
	case .Type_Is_Matrix_Row_Major, .Type_Is_Matrix_Column_Major:
		entry := types.get(store, types.resolve_named(store, operand.type))
		if entry.kind != .Matrix { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
		return expression_type_bool(checker, view, scope, node, entry.row_major == (kind == .Type_Is_Matrix_Row_Major))
	}
	return expression_type_bool(checker, view, scope, node, type_predicate(store, kind, operand.type))
}

// Whether a builtin kind is answered by expression_type_predicate. The two polymorphic-record predicates and
// type_is_specialization_of are deliberately absent: with no polymorphic-record representation in src/types they keep
// falling through to Unsupported instead of silently answering false.
@(private = "package")
builtin_type_predicate_kind :: proc(kind: Builtin_Kind) -> bool {
	if kind >= .Type_Comparable && kind <= .Type_Core_Type { return true }
	#partial switch kind {
	case .Type_Has_Nil,
	     .Type_Is_Any,
	     .Type_Is_Bit_Field,
	     .Type_Is_Complex,
	     .Type_Is_Cstring,
	     .Type_Is_Cstring16,
	     .Type_Is_Dereferenceable,
	     .Type_Is_Endian_Big,
	     .Type_Is_Endian_Little,
	     .Type_Is_Endian_Platform,
	     .Type_Is_Fixed_Capacity_Dynamic_Array,
	     .Type_Is_Indexable,
	     .Type_Is_Matrix,
	     .Type_Is_Matrix_Column_Major,
	     .Type_Is_Matrix_Row_Major,
	     .Type_Is_Named,
	     .Type_Is_Nearly_Simple_Compare,
	     .Type_Is_Quaternion,
	     .Type_Is_Rune,
	     .Type_Is_Simd_Vector,
	     .Type_Is_Sliceable,
	     .Type_Is_String,
	     .Type_Is_String16,
	     .Type_Is_Subtype_Of,
	     .Type_Is_Superset_Of,
	     .Type_Is_Typeid,
	     .Type_Is_Valid_Map_Key,
	     .Type_Is_Valid_Matrix_Elements,
	     .Type_Is_Variant_Of:
		return true
	}
	return false
}

// The single-argument predicates. Each unwraps with resolve_named (upstream base_type) or core_type (upstream
// core_type) exactly as its upstream `is_type_*` does; see the probe table in builtin_type_predicates_test.odin.
@(private = "file")
type_predicate :: proc(store: ^types.Store, kind: Builtin_Kind, id: types.Type_Id) -> bool {
	descriptor := types.get(store, types.resolve_named(store, id))
	core := types.get(store, types.core_type(store, id))
	#partial switch kind {
	case .Type_Comparable:
		return types.is_comparable(store, id)
	case .Type_Ordered:
		return types.is_ordered(store, id)
	case .Type_Ordered_Numeric:
		return types.is_ordered_numeric(store, id)
	case .Type_Simple_Compare:
		return types.is_simple_compare(store, id)
	case .Type_Enumerated_Array:
		return types.is_enumerated_array(store, id)
	case .Type_Has_Nil:
		return type_has_nil(descriptor)
	case .Type_Is_Any:
		return descriptor.kind == .Any
	case .Type_Is_Bit_Field:
		return descriptor.kind == .Bit_Field
	case .Type_Is_Complex:
		return core.kind == .Complex || core.kind == .Untyped_Complex
	case .Type_Is_Cstring:
		return descriptor.kind == .CString
	case .Type_Is_Cstring16:
		return descriptor.kind == .CString16
	case .Type_Is_Dereferenceable:
		if types.get(store, id).kind == .Raw_Pointer { return false }
		return descriptor.kind == .Pointer || descriptor.kind == .Soa_Pointer
	case .Type_Is_Endian_Big:
		specificity := type_endianness(store, id)
		return specificity == .Big || (specificity == .Platform && !target_is_little_endian())
	case .Type_Is_Endian_Little:
		specificity := type_endianness(store, id)
		return specificity == .Little || (specificity == .Platform && target_is_little_endian())
	case .Type_Is_Endian_Platform:
		return type_endianness(store, id) == .Platform
	case .Type_Is_Fixed_Capacity_Dynamic_Array:
		return descriptor.kind == .Fixed_Capacity_Array
	case .Type_Is_Indexable:
		#partial switch descriptor.kind {
		case .String, .String16, .Array, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Map, .Multi_Pointer, .Enumerated_Array, .Matrix:
			return true
		}
		return false
	case .Type_Is_Matrix:
		return descriptor.kind == .Matrix
	case .Type_Is_Named:
		outer := types.get(store, id)
		return outer.kind == .Named || is_basic_kind(outer.kind)
	case .Type_Is_Nearly_Simple_Compare:
		return is_nearly_simple_compare(store, id)
	case .Type_Is_Quaternion:
		return core.kind == .Quaternion || core.kind == .Untyped_Quaternion
	case .Type_Is_Rune:
		return descriptor.kind == .Rune || descriptor.kind == .Untyped_Rune
	case .Type_Is_Simd_Vector:
		return descriptor.kind == .Simd_Vector
	case .Type_Is_Sliceable:
		#partial switch descriptor.kind {
		case .String, .String16, .Array, .Slice, .Dynamic_Array, .Fixed_Capacity_Array:
			return true
		}
		return false
	case .Type_Is_String:
		#partial switch descriptor.kind {
		case .String, .String16, .CString, .CString16, .Untyped_String:
			return true
		}
		return false
	case .Type_Is_String16:
		return descriptor.kind == .String16
	case .Type_Is_Typeid:
		return descriptor.kind == .Type_Id
	case .Type_Is_Valid_Map_Key:
		cored := types.core_type(store, id)
		if types.is_untyped(store, cored) { return false }
		size, _, layout_error := types.layout(store, cored)
		return layout_error == .None && size > 0 && types.is_comparable(store, id)
	case .Type_Is_Valid_Matrix_Elements:
		#partial switch descriptor.kind {
		case .Integer, .Rune, .Float, .Complex, .Untyped_Integer, .Untyped_Rune, .Untyped_Float, .Untyped_Complex:
			return true
		}
		return false
	}
	return false
}

// Whether the kind lowers to an upstream Basic type, which is what upstream `is_type_named` accepts.
@(private = "file")
is_basic_kind :: proc(kind: types.Kind) -> bool {
	#partial switch kind {
	case .Bool,
	     .Integer,
	     .Float,
	     .Rune,
	     .Complex,
	     .Quaternion,
	     .String,
	     .String16,
	     .CString,
	     .CString16,
	     .Raw_Pointer,
	     .Any,
	     .Type_Id,
	     .Untyped_Bool,
	     .Untyped_Integer,
	     .Untyped_Rune,
	     .Untyped_Float,
	     .Untyped_Complex,
	     .Untyped_Quaternion,
	     .Untyped_String,
	     .Untyped_Nil:
		return true
	}
	return false
}

// Upstream `type_has_nil`: pointers, maps, slices, dynamic arrays, procedures, enums, bit sets, cstrings, any and
// typeid can be nil; fixed arrays, raw unions and plain structs cannot; unions can unless #no_nil.
@(private = "file")
type_has_nil :: proc(descriptor: ^types.Type) -> bool {
	#partial switch descriptor.kind {
	case .Raw_Pointer, .Any, .CString, .CString16, .Type_Id:
		return true
	case .Enum, .Bit_Set:
		return true
	case .Slice, .Procedure, .Pointer, .Soa_Pointer, .Multi_Pointer, .Dynamic_Array, .Map:
		return true
	case .Fixed_Capacity_Array:
		return false
	case .Union:
		return descriptor.union_form != .No_Nil
	case .Struct:
		#partial switch descriptor.soa {
		case .Fixed:
			return false
		case .Slice, .Dynamic:
			return true
		}
	}
	return false
}

// Upstream `is_type_nearly_simple_compare`: memcmp comparison also covers floats, unlike simple comparison.
@(private = "file")
is_nearly_simple_compare :: proc(store: ^types.Store, id: types.Type_Id) -> bool {
	descriptor := types.get(store, types.core_type(store, id))
	#partial switch descriptor.kind {
	case .Array, .Enumerated_Array:
		return is_nearly_simple_compare(store, descriptor.elem)
	case .Fixed_Capacity_Array:
		return false
	case .Bool,
	     .Integer,
	     .Rune,
	     .Raw_Pointer,
	     .Float,
	     .Complex,
	     .Quaternion,
	     .Type_Id,
	     .Untyped_Bool,
	     .Untyped_Integer,
	     .Untyped_Rune,
	     .Untyped_Float,
	     .Untyped_Complex,
	     .Untyped_Quaternion:
		return true
	case .Pointer, .Multi_Pointer, .Soa_Pointer, .Procedure, .Bit_Set, .Bit_Field:
		return true
	case .Matrix, .Simd_Vector:
		return is_nearly_simple_compare(store, descriptor.elem)
	case .Struct:
		for field in descriptor.fields {
			if !is_nearly_simple_compare(store, field.type) { return false }
		}
		return true
	case .Union:
		for variant in descriptor.variants {
			if !is_nearly_simple_compare(store, variant) { return false }
		}
		return len(descriptor.variants) == 1
	case .Tuple:
		if len(descriptor.fields) == 1 { return is_nearly_simple_compare(store, descriptor.fields[0].type) }
	case .Slice, .Dynamic_Array, .Map:
		return false
	}
	return false
}

Endian_Specificity :: enum {
	None,
	Platform,
	Little,
	Big,
}

// Upstream `type_endian_kind_of`: basic types and bit-set backings carry explicit endianness, pointers use uintptr,
// and anything else has none.
@(private = "file")
type_endianness :: proc(store: ^types.Store, id: types.Type_Id) -> Endian_Specificity {
	resolved := types.core_type(store, id)
	descriptor := types.get(store, resolved)
	#partial switch descriptor.kind {
	case .Bool,
	     .Integer,
	     .Float,
	     .Rune,
	     .Complex,
	     .Quaternion,
	     .String,
	     .String16,
	     .CString,
	     .CString16,
	     .Raw_Pointer,
	     .Any,
	     .Type_Id,
	     .Untyped_Bool,
	     .Untyped_Integer,
	     .Untyped_Rune,
	     .Untyped_Float,
	     .Untyped_Complex,
	     .Untyped_Quaternion,
	     .Untyped_String,
	     .Untyped_Nil:
		#partial switch descriptor.endianness {
		case .Little:
			return .Little
		case .Big:
			return .Big
		case .Native:
			return .Platform
		}
	case .Bit_Set:
		backing, found := bit_set_backing_int(store, resolved)
		if found { return type_endianness(store, backing) }
	case .Pointer, .Multi_Pointer:
		return .Platform
	}
	return .None
}

// Upstream `bit_set_to_int`: an integer backing decides, otherwise the size selects an unsigned integer.
@(private = "file")
bit_set_backing_int :: proc(store: ^types.Store, id: types.Type_Id) -> (backing: types.Type_Id, found: bool) {
	descriptor := types.get(store, id)
	if descriptor.kind != .Bit_Set { return types.TYPE_NONE, false }
	if descriptor.backing != types.TYPE_NONE && types.get(store, types.resolve_named(store, descriptor.backing)).kind == .Integer {
		return descriptor.backing, true
	}
	size, _, layout_error := types.layout(store, id)
	if layout_error != .None { return types.TYPE_NONE, false }
	return types.sized_integer(store, size, false), true
}

// The only codegen target is Linux x86-64, which is little-endian.
@(private = "file")
target_is_little_endian :: proc() -> bool { return true }

@(private = "file")
expression_type_bool :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	result: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	constant, failure := constant_pool_intern_bool(checker.constants, result, types.TYPE_UNTYPED_BOOL)
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_BOOL, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

// The two-argument relations: variant membership, subtype identity, and the enum/union superset check of
// check_builtin.cpp. Subtype answers true only for identical types on concrete types.
@(private = "file")
expression_type_relation :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 2 || ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	first := type_query_operand(checker, view, scope, arguments[0]) or_return
	if first.state == .Invalid { return expression_poison(scope), nil }
	if first.mode != .Type { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	second := type_query_operand(checker, view, scope, arguments[1]) or_return
	if second.state == .Invalid { return expression_poison(scope), nil }
	if second.mode != .Type { return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand) }
	store := checker.type_checker.store
	result := false
	valid := true
	#partial switch kind {
	case .Type_Is_Variant_Of:
		union_descriptor := types.get(store, types.resolve_named(store, first.type))
		if union_descriptor.kind != .Union {
			return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
		}
		for variant in union_descriptor.variants {
			if types.are_identical(store, variant, second.type) { result = true; break }
		}
	case .Type_Is_Subtype_Of:
		result = types.are_identical(store, first.type, second.type)
	case .Type_Is_Superset_Of:
		result, valid = type_superset_of(checker, first.type, second.type)
	}
	if !valid { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	return expression_type_bool(checker, view, scope, node, result)
}

// Upstream `type_is_superset_of`: identical types match; enums need every sub member by name and value with an
// identical backing; unions need the sub variants as an identical prefix with the same form.
@(private = "file")
type_superset_of :: proc(checker: ^Expression_Checker, super, sub: types.Type_Id) -> (result: bool, valid: bool) {
	store := checker.type_checker.store
	if types.are_identical(store, super, sub) { return true, true }
	super_named := types.resolve_named(store, super)
	sub_named := types.resolve_named(store, sub)
	if types.are_identical(store, super_named, sub_named) { return true, true }
	super_descriptor := types.get(store, super_named)
	sub_descriptor := types.get(store, sub_named)
	if super_descriptor.kind != sub_descriptor.kind { return false, false }
	#partial switch super_descriptor.kind {
	case .Enum:
		super_members := checker.type_checker.enum_members[super_named]
		sub_members := checker.type_checker.enum_members[sub_named]
		if len(sub_members) > len(super_members) { return false, true }
		if !types.are_identical(store, super_descriptor.backing, sub_descriptor.backing) { return false, true }
		for sub_member in sub_members {
			matched := false
			for super_member in super_members {
				if super_member.name == sub_member.name && super_member.value == sub_member.value {
					matched = true
					break
				}
			}
			if !matched { return false, true }
		}
		return true, true
	case .Union:
		if len(sub_descriptor.variants) > len(super_descriptor.variants) { return false, true }
		if sub_descriptor.union_form != super_descriptor.union_form { return false, true }
		for variant, index in sub_descriptor.variants {
			if !types.are_identical(store, variant, super_descriptor.variants[index]) { return false, true }
		}
		return true, true
	}
	return false, false
}
