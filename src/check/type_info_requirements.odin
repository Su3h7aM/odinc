package check

import "base:runtime"
import "core:mem"
import "oc:syntax"
import "oc:types"

// The `typeid` value of a type; the entry of its runtime type info is found by `type` in `runtime_type_info`.
Typeid_Plan :: struct {
	type: types.Type_Id,
}

Type_Info_Plan :: struct {
	type:  types.Type_Id,
	table: Entity_Id,
}

@(private = "package")
expression_type_info_of :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_failure(checker, view, scope, node, .Unsupported) }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	if operand.mode != .Type && types.get(store, types.resolve_named(store, operand.type)).kind != .Type_Id {
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
	}
	collection := checker.type_checker.collection
	if collection == nil || collection.runtime_scope == 0 { return expression_failure(checker, view, scope, node, .Unsupported) }
	scopes := checker.type_checker.resolver.scopes
	if operand.mode != .Type {
		expression_record_type_info(checker, operand.type) or_return
		helper := scope_lookup_current(scopes, collection.runtime_scope, "__type_info_of")
		if helper == 0 { return expression_failure(checker, view, scope, node, .Unsupported) }
		_, resolve_error := resolve_entity(checker.type_checker.resolver, helper)
		if resolve_error != nil { return {}, resolve_error }
		if entity_get(scopes, helper).state != .Resolved { return expression_failure(checker, view, scope, node, .Unsupported) }
		callee := Expression_Info {
			entity = helper,
			type   = entity_get(scopes, helper).type,
			mode   = .Value,
			state  = .Checked,
		}
		return expression_call(checker, view, checker.views[view].file, scope, node, callee, arguments, false)
	}
	info_type := runtime_type_named(checker, "Type_Info")
	table := scope_lookup_current(scopes, collection.runtime_scope, "type_table")
	if info_type == 0 || table == 0 { return expression_failure(checker, view, scope, node, .Unsupported) }
	_, resolve_error := resolve_entity(checker.type_checker.resolver, table)
	if resolve_error != nil { return {}, resolve_error }
	expression_record_type_info(checker, operand.type) or_return
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Type_Info_Plan{type = operand.type, table = table})) or_return
	result := types.intern(store, types.Type{kind = .Pointer, elem = info_type})
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// Kinds of the typeid encoding; the numbering matches the official compiler's Typeid_Kind.
Typeid_Kind :: enum u8 {
	Invalid,
	Integer,
	Rune,
	Float,
	Complex,
	Quaternion,
	String,
	Boolean,
	Any,
	Type_Id,
	Pointer,
	Multi_Pointer,
	Procedure,
	Array,
	Enumerated_Array,
	Dynamic_Array,
	Slice,
	Tuple,
	Struct,
	Union,
	Enum,
	Map,
	Bit_Set,
	Simd_Vector,
	Matrix,
	Soa_Pointer,
	Bit_Field,
	Fixed_Capacity_Dynamic_Array,
}

// The members of an enum type, in declaration order, for its runtime names and values.
Enum_Type_Members :: struct {
	type:    types.Type_Id,
	members: []Enum_Member,
}

@(private = "package")
expression_typeid_of :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_failure(checker, view, scope, node, .Unsupported) }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	expression_record_type_info(checker, operand.type) or_return
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Typeid_Plan{type = operand.type})) or_return
	typeid_type := types.intern(checker.type_checker.store, types.Type{kind = .Type_Id})
	return Expression_Info{type = typeid_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// A type whose runtime type info is needed: its typeid is used or it is converted to `any`.
@(private = "package")
expression_record_type_info :: proc(checker: ^Expression_Checker, type: types.Type_Id) -> runtime.Allocator_Error {
	for root in checker.type_info_roots {
		if root == type { return nil }
	}
	append(&checker.type_info_roots, type) or_return
	return nil
}

// Publishes the runtime type info of every recorded type and of the types they refer to, in first-use order.
@(private = "package")
expression_checker_publish_type_info :: proc(checker: ^Expression_Checker, program: ^Checked_Program) -> runtime.Allocator_Error {
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	store := checker.type_checker.store
	ordered := make([dynamic]types.Type_Id, allocator) or_return
	seen := make([dynamic]bool, allocator) or_return
	for root in checker.type_info_roots {
		collect_type_info_types(store, root, &ordered, &seen) or_return
	}
	entries := make([]Type_Info_Entry, len(ordered), allocator) or_return
	members := make([dynamic]Enum_Type_Members, allocator) or_return
	for type, index in ordered {
		size, alignment, _ := types.layout(store, type)
		slot := u32(index + 1)
		entries[index] = Type_Info_Entry {
			type       = type,
			runtime_id = typeid_encoding(store, type, slot),
			slot       = slot,
			size       = size,
			alignment  = alignment,
		}
		resolved := types.resolve_named(store, type)
		if types.get(store, resolved).kind != .Enum { continue }
		enum_members, found := checker.type_checker.enum_members[resolved]
		if found { append(&members, Enum_Type_Members{type = resolved, members = enum_members}) or_return }
	}
	program.runtime.type_info = entries
	program.runtime.enum_members = members[:]
	program.runtime.type_info_type = runtime_type_named(checker, "Type_Info")
	program.runtime.type_info_parameters_type = runtime_type_named(checker, "Type_Info_Parameters")
	return nil
}

// The integer type that stores the variant tag of a union, or TYPE_NONE when the union has no tag.
// Interning returns the existing id once the union has been collected, so lowering may call it too.
union_tag_type :: proc(store: ^types.Store, union_type: types.Type_Id) -> types.Type_Id {
	layout, layout_error := types.union_layout(store, union_type)
	if layout_error != .None || layout.tag_size == 0 { return types.TYPE_NONE }
	return types.intern(store, types.Type{kind = .Integer, count = layout.tag_size})
}

// The runtime declaration of `name`, resolved so that its layout is known to lowering.
@(private = "file")
runtime_type_named :: proc(checker: ^Expression_Checker, name: string) -> types.Type_Id {
	collection := checker.type_checker.collection
	if collection == nil || collection.runtime_scope == 0 { return types.TYPE_NONE }
	scopes := checker.type_checker.resolver.scopes
	entity := scope_lookup_current(scopes, collection.runtime_scope, name)
	if entity == 0 { return types.TYPE_NONE }
	if _, resolve_error := resolve_entity(checker.type_checker.resolver, entity); resolve_error != nil { return types.TYPE_NONE }
	return entity_get(scopes, entity).type
}

// Depth-first, in the order of each descriptor's references: elem, index, backing, fields, variants, params, results.
// A union also refers to its tag type, collected after its variants.
@(private = "file")
collect_type_info_types :: proc(store: ^types.Store, type: types.Type_Id, ordered: ^[dynamic]types.Type_Id, seen: ^[dynamic]bool) -> runtime.Allocator_Error {
	if type == types.TYPE_NONE { return nil }
	for int(type) >= len(seen) { append(seen, false) or_return }
	if seen[type] { return nil }
	seen[type] = true
	append(ordered, type) or_return
	descriptor := types.get(store, type)^
	children := [?]types.Type_Id{descriptor.elem, descriptor.index, descriptor.backing}
	for child in children {
		collect_type_info_types(store, child, ordered, seen) or_return
	}
	for field in descriptor.fields {
		collect_type_info_types(store, field.type, ordered, seen) or_return
	}
	for group in ([?][]types.Type_Id{descriptor.variants, descriptor.params, descriptor.results}) {
		for child in group {
			collect_type_info_types(store, child, ordered, seen) or_return
		}
	}
	if descriptor.kind == .Union {
		collect_type_info_types(store, union_tag_type(store, type), ordered, seen) or_return
	}
	return nil
}

// Index in the low 56 bits; kind, named and special in the top bits, as the official encoding (cg_typeid_as_u64).
@(private = "file")
typeid_encoding :: proc(store: ^types.Store, type: types.Type_Id, slot: u32) -> u64 {
	descriptor := types.get(store, types.resolve_named(store, type))
	kind := typeid_kind(descriptor.kind)
	named := u64(types.get(store, type).kind == .Named)
	special := u64(descriptor.kind == .CString || (descriptor.kind == .Integer && descriptor.signed))
	return u64(slot) | u64(kind) << 56 | named << 61 | special << 62
}

@(private = "file")
typeid_kind :: proc(kind: types.Kind) -> Typeid_Kind {
	#partial switch kind {
	case .Integer:
		return .Integer
	case .Rune:
		return .Rune
	case .Float:
		return .Float
	case .Complex:
		return .Complex
	case .Quaternion:
		return .Quaternion
	case .String, .String16, .CString, .CString16:
		return .String
	case .Bool:
		return .Boolean
	case .Any:
		return .Any
	case .Type_Id:
		return .Type_Id
	case .Raw_Pointer, .Pointer:
		return .Pointer
	case .Multi_Pointer:
		return .Multi_Pointer
	case .Procedure:
		return .Procedure
	case .Array, .Fixed_Capacity_Array:
		return .Array
	case .Enumerated_Array:
		return .Enumerated_Array
	case .Dynamic_Array:
		return .Dynamic_Array
	case .Slice:
		return .Slice
	case .Tuple:
		return .Tuple
	case .Struct:
		return .Struct
	case .Union:
		return .Union
	case .Enum:
		return .Enum
	case .Map:
		return .Map
	case .Bit_Set:
		return .Bit_Set
	case .Simd_Vector:
		return .Simd_Vector
	case .Matrix:
		return .Matrix
	case .Soa_Pointer:
		return .Soa_Pointer
	case .Bit_Field:
		return .Bit_Field
	}
	return .Invalid
}
