package check

import "base:runtime"
import "core:mem"
import "core:strconv"
import "oc:syntax"
import "oc:types"

Type_Diagnostic_Kind :: enum u8 {
	None,
	Undeclared_Type,
	Not_A_Type,
	Unsupported_Type_Expression,
	Invalid_Array_Count,
	Invalid_Alignment,
	Missing_Evaluator,
	Missing_Field_Type,
	Invalid_Name,
	Duplicate_Field,
	Duplicate_Variant,
	Duplicate_Enum_Member,
	Invalid_Enum_Base,
	Enum_Value_Out_Of_Range,
	Invalid_Calling_Convention,
	Invalid_Distinct,
	Recursive_Value,
	Invalid_Bit_Set_Element,
	Invalid_Bit_Set_Backing,
	Bit_Set_Out_Of_Range,
	Invalid_Simd_Count,
	Invalid_Simd_Element,
	Invalid_Bit_Field_Backing,
	Invalid_Bit_Field_Field,
	Bit_Field_Out_Of_Range,
	Invalid_Record_Arguments,
	Unsatisfied_Where_Clause,
	Invalid_Optional_Result,
	Non_Contiguous_Enum_Index,
	Invalid_Matrix_Count,
	Invalid_Matrix_Element,
}

@(private = "file")
runtime_allocator_error :: proc(checker: ^Type_Checker) -> types.Type_Id {
	collection := checker.collection
	if collection == nil || collection.runtime_scope == 0 { return types.TYPE_NONE }
	scopes := checker.resolver.scopes
	entity := scope_lookup_current(scopes, collection.runtime_scope, "Allocator_Error")
	if entity == 0 { return types.TYPE_NONE }
	if _, resolve_error := resolve_entity(checker.resolver, entity); resolve_error != nil { return types.TYPE_NONE }
	return entity_get(scopes, entity).type
}

@(private = "file")
optional_result_valid :: proc(checker: ^Type_Checker, result_types: []types.Type_Id, allocator: bool) -> bool {
	if len(result_types) != 2 { return false }
	if allocator { return result_types[1] == runtime_allocator_error(checker) }
	return types.get(checker.store, types.resolve_named(checker.store, result_types[1])).kind == .Bool
}


// Placeholder for F3. Names and source bytes are borrowed.
Type_Diagnostic :: struct {
	kind:   Type_Diagnostic_Kind,
	name:   string,
	source: Source_Span,
}

Enum_Member :: struct {
	name:   string,
	value:  i64,
	source: Source_Span,
}

Nominal_Type :: struct {
	entity: Entity_Id,
	type:   types.Type_Id,
}

// Evaluates an integer constant expression in `scope`. False means the evaluator diagnosed it already.
Integer_Evaluator :: #type proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> (
	value: i64,
	ok: bool,
	err: Resolve_Error,
)

Enum_Member_Binder :: #type proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	name: string,
	value: i64,
	backing: types.Type_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> Resolve_Error

// Evaluates a boolean constant condition in `scope`. False means the evaluator diagnosed it already.
Boolean_Evaluator :: #type proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> (
	value: bool,
	ok: bool,
	err: Resolve_Error,
)

// Evaluates the default expression of an untyped parameter and returns its default type. False means it was diagnosed already.
Default_Type_Evaluator :: #type proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> (
	type_id: types.Type_Id,
	ok: bool,
	err: Resolve_Error,
)

// Zero means a non-type expression; poison means it was diagnosed already.
Type_Expression_Evaluator :: #type proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> (
	type_id: types.Type_Id,
	err: Resolve_Error,
)

// Resolves type expressions into the borrowed type store. Run it serially with the borrowed resolver.
// Owns member arrays, enum metadata, diagnostics and lookup tables. `files` is indexed by File_Id.
// The declaration dispatcher passed to resolver_init calls type_declaration for each entity first.
Type_Checker :: struct {
	resolver:                 ^Resolver,
	collection:               ^Collection,
	store:                    ^types.Store,
	files:                    []^File,
	packages:                 []Package,
	evaluate_integer:         Integer_Evaluator,
	bind_enum_member:         Enum_Member_Binder,
	evaluate_boolean:         Boolean_Evaluator,
	evaluate_default_type:    Default_Type_Evaluator,
	evaluate_type_expression: Type_Expression_Evaluator,
	user_data:                rawptr,
	instantiating:            bool,
	record_instance:          Instance_Id,
	evaluate_record_argument: Record_Argument_Evaluator,
	generic_records:          map[Entity_Id]Node_Ref,
	record_instances:         [dynamic]Record_Instance,
	allocator:                mem.Allocator,
	arena:                    mem.Dynamic_Arena,
	arena_allocator:          mem.Allocator,
	declarations:             map[Entity_Id]Collected_Declaration,
	synced:                   int,
	enum_members:             map[types.Type_Id][]Enum_Member,
	field_flags:              map[types.Type_Id][]syntax.Field_Flags,
	nominals:                 [dynamic]Nominal_Type,
	layouts_checked:          int,
	diagnostics:              [dynamic]Type_Diagnostic,
}

type_checker_init :: proc(
	checker: ^Type_Checker,
	resolver: ^Resolver,
	collection: ^Collection,
	store: ^types.Store,
	files: []^File,
	evaluator: Integer_Evaluator,
	user_data: rawptr,
	allocator: mem.Allocator,
) {
	assert(checker != nil && checker.resolver == nil && resolver != nil && collection != nil && store != nil)
	assert(allocator.procedure != nil)
	checker.resolver = resolver
	checker.collection = collection
	checker.store = store
	checker.files = files
	checker.evaluate_integer = evaluator
	checker.user_data = user_data
	checker.allocator = allocator
	mem.dynamic_arena_init(&checker.arena, block_allocator = allocator, array_allocator = allocator)
	checker.arena_allocator = mem.dynamic_arena_allocator(&checker.arena)
	checker.generic_records = make(map[Entity_Id]Node_Ref, checker.arena_allocator)
	checker.record_instances.allocator = checker.arena_allocator
	checker.declarations = make(map[Entity_Id]Collected_Declaration, allocator)
	checker.enum_members = make(map[types.Type_Id][]Enum_Member, allocator)
	checker.field_flags = make(map[types.Type_Id][]syntax.Field_Flags, allocator)
	checker.nominals.allocator = allocator
	checker.diagnostics.allocator = allocator
}

type_checker_destroy :: proc(checker: ^Type_Checker) {
	if checker == nil { return }
	delete(checker.declarations)
	delete(checker.enum_members)
	delete(checker.field_flags)
	delete(checker.nominals)
	delete(checker.diagnostics)
	mem.dynamic_arena_destroy(&checker.arena)
	checker^ = {}
}

// Handles Type_Name entities and constants that alias a type. Other entities are left to their checkers.
// Nominal records publish their identity before members are resolved. Layout cycles are found by
// check_nominal_layouts after the nominal graph is complete.
@(require_results)
type_declaration :: proc(checker: ^Type_Checker, id: Entity_Id) -> (handled, valid: bool, err: Resolve_Error) {
	type_checker_sync(checker) or_return
	collected, found := checker.declarations[id]
	if !found || collected.value.node == 0 { return }
	scopes := checker.resolver.scopes
	entity := entity_get(scopes, id)
	if entity.kind != .Type_Name && entity.kind != .Constant { return }
	file_id := collected.value.file
	file := checker.files[file_id]
	scope, name := entity.scope, entity.name
	value := type_unparen(file, collected.value.node)
	if entity.kind == .Constant {
		is_type := type_value_is_type(checker, file_id, file, scope, value) or_return
		if !is_type { return }
		entity = entity_get(scopes, id)
		entity.kind = .Type_Name
	}
	handled = true
	record := value
	if file.ast.nodes[record].kind == .Distinct_Type {
		record = type_unparen(file, syntax.node_payload(file.ast, record, syntax.Distinct_Type).type)
	}
	if record_poly_params(file, record) != 0 {
		checker.generic_records[id] = Node_Ref{file_id, record}
		return true, true, nil
	}
	#partial switch file.ast.nodes[value].kind {
	case .Struct_Type:
		type := publish_nominal(checker, id, .Struct, name) or_return
		descriptor, field_flags, record_valid := struct_descriptor(checker, file_id, file, scope, value, name) or_return
		register_field_flags(checker, type, field_flags) or_return
		types.complete_nominal(checker.store, type, descriptor)
		return true, record_valid, nil
	case .Union_Type:
		type := publish_nominal(checker, id, .Union, name) or_return
		descriptor, record_valid := union_descriptor(checker, file_id, file, scope, value, name) or_return
		types.complete_nominal(checker.store, type, descriptor)
		return true, record_valid, nil
	case .Enum_Type:
		type := publish_nominal(checker, id, .Enum, name) or_return
		descriptor, members, record_valid := enum_descriptor(checker, file_id, file, scope, value, name) or_return
		register_enum(checker, type, members) or_return
		types.complete_nominal(checker.store, type, descriptor)
		return true, record_valid, nil
	case .Distinct_Type:
		type := publish_nominal(checker, id, .Named, name) or_return
		base := type_expression(checker, file_id, scope, syntax.node_payload(file.ast, value, syntax.Distinct_Type).type, true) or_return
		types.complete_nominal(checker.store, type, types.Type{kind = .Named, name = name, elem = base})
		return true, base != types.TYPE_POISON, nil
	}
	type := type_expression(checker, file_id, scope, value, true) or_return
	entity = entity_get(scopes, id)
	entity.type = type
	entity.flags += {.Type_Alias}
	return true, type != types.TYPE_POISON, nil
}

// The taken branch of a ternary when; ok is false after the condition has been diagnosed.
@(private = "file")
type_ternary_when_branch :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	branch: syntax.Node_Index,
	ok: bool,
	err: Resolve_Error,
) {
	ternary := syntax.node_payload(file.ast, node, syntax.Ternary_Expr)
	if checker.evaluate_boolean == nil {
		type_report(checker, file_id, file, node, .Missing_Evaluator) or_return
		return 0, false, nil
	}
	value, evaluated, evaluate_error := checker.evaluate_boolean(checker, scope, file_id, ternary.cond, checker.user_data)
	if evaluate_error != nil || !evaluated { return 0, false, evaluate_error }
	if value { return ternary.x, true, nil }
	return ternary.y, true, nil
}

// A constant names a type when its value is a type node, an alias, or a ternary when selecting one.
@(private = "file")
type_value_is_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	is_type: bool,
	err: Resolve_Error,
) {
	#partial switch file.ast.nodes[node].kind {
	case .Ident:
		return type_alias_target(checker, file_id, file, scope, node)
	case .Selector_Expr:
		return type_alias_target(checker, file_id, file, scope, node)
	case .Call_Expr:
		if is_type_of_call(file, node) { return true, nil }
		definition := record_call_definition(checker, file_id, file, scope, node) or_return
		return definition != 0, nil
	case .Ternary_When_Expr:
		branch, selected, branch_error := type_ternary_when_branch(checker, file_id, file, scope, node)
		if branch_error != nil || !selected { return false, branch_error }
		return type_value_is_type(checker, file_id, file, scope, branch)
	case:
		return file.ast.nodes[node].kind >= .Typeid_Type && file.ast.nodes[node].kind <= .Bit_Field_Type, nil
	}
}

// Poison is returned after a diagnosed error. Direct positions need the value's layout; indirect ones
// need only its identity. Both request identity so mutually recursive nominals can be declared.
@(require_results)
type_expression :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	scope: Scope_Id,
	expression: syntax.Node_Index,
	direct: bool,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	file := checker.files[file_id]
	node := type_unparen(file, expression)
	#partial switch file.ast.nodes[node].kind {
	case .Ident:
		return type_identifier(checker, file_id, file, scope, node, direct)
	case .Selector_Expr:
		return type_selector(checker, file_id, file, scope, node, direct)
	case .Ternary_When_Expr:
		branch, selected, branch_error := type_ternary_when_branch(checker, file_id, file, scope, node)
		if branch_error != nil || !selected { return types.TYPE_POISON, branch_error }
		return type_expression(checker, file_id, scope, branch, direct)
	case .Pointer_Type:
		elem := type_expression(checker, file_id, scope, syntax.node_payload(file.ast, node, syntax.Pointer_Type).elem, false) or_return
		return type_wrapper(checker, .Pointer, elem), nil
	case .Multi_Pointer_Type:
		elem := type_expression(checker, file_id, scope, syntax.node_payload(file.ast, node, syntax.Multi_Pointer_Type).elem, false) or_return
		return type_wrapper(checker, .Multi_Pointer, elem), nil
	case .Poly_Type:
		return type_expression(checker, file_id, scope, syntax.node_payload(file.ast, node, syntax.Poly_Type).type, direct)
	case .Dynamic_Array_Type:
		elem := type_expression(checker, file_id, scope, syntax.node_payload(file.ast, node, syntax.Dynamic_Array_Type).elem, false) or_return
		return type_wrapper(checker, .Dynamic_Array, elem), nil
	case .Fixed_Capacity_Dynamic_Array_Type:
		array := syntax.node_payload(file.ast, node, syntax.Fixed_Capacity_Dynamic_Array_Type)
		count, count_valid := array_count(checker, file_id, scope, array.capacity) or_return
		elem := type_expression(checker, file_id, scope, array.elem, true) or_return
		if !count_valid || elem == types.TYPE_POISON { return types.TYPE_POISON, nil }
		return types.intern(checker.store, types.Type{kind = .Fixed_Capacity_Array, elem = elem, count = count}), nil
	case .Array_Type:
		return array_type(checker, file_id, file, scope, node)
	case .Call_Expr:
		if is_type_of_call(file, node) { return type_of_type(checker, file_id, file, scope, node) }
		return record_type_call(checker, file_id, file, scope, node)
	case .Bit_Set_Type:
		return bit_set_type(checker, file_id, file, scope, node)
	case .Matrix_Type:
		return matrix_type(checker, file_id, file, scope, node)
	case .Bit_Field_Type:
		return bit_field_type(checker, file_id, file, scope, node)
	case .Typeid_Type:
		if syntax.node_payload(file.ast, node, syntax.Typeid_Type).specialization == 0 {
			return types.intern(checker.store, types.Type{kind = .Type_Id}), nil
		}
	case .Map_Type:
		map_type := syntax.node_payload(file.ast, node, syntax.Map_Type)
		key := type_expression(checker, file_id, scope, map_type.key, false) or_return
		value := type_expression(checker, file_id, scope, map_type.value, false) or_return
		if key == types.TYPE_POISON || value == types.TYPE_POISON { return types.TYPE_POISON, nil }
		return types.intern(checker.store, types.Type{kind = .Map, index = key, elem = value}), nil
	case .Struct_Type:
		descriptor, field_flags, valid := struct_descriptor(checker, file_id, file, scope, node, "") or_return
		if !valid { return types.TYPE_POISON, nil }
		type = types.intern(checker.store, descriptor)
		register_field_flags(checker, type, field_flags) or_return
		return type, nil
	case .Union_Type:
		descriptor, valid := union_descriptor(checker, file_id, file, scope, node, "") or_return
		if !valid { return types.TYPE_POISON, nil }
		return types.intern(checker.store, descriptor), nil
	case .Enum_Type:
		descriptor, members, valid := enum_descriptor(checker, file_id, file, scope, node, "") or_return
		if !valid { return types.TYPE_POISON, nil }
		type = types.intern(checker.store, descriptor)
		register_enum(checker, type, members) or_return
		return type, nil
	case .Proc_Type:
		return procedure_type(checker, file_id, file, scope, node)
	case .Helper_Type:
		return type_expression(checker, file_id, scope, syntax.node_payload(file.ast, node, syntax.Helper_Type).type, direct)
	case .Distinct_Type:
		type_report(checker, file_id, file, node, .Invalid_Distinct) or_return
		return types.TYPE_POISON, nil
	}
	type_report(checker, file_id, file, node, .Unsupported_Type_Expression) or_return
	return types.TYPE_POISON, nil
}

// Reports direct-value cycles among completed nominal records. Entities with a cycle become invalid.
check_nominal_layouts :: proc(checker: ^Type_Checker) -> runtime.Allocator_Error {
	scopes := checker.resolver.scopes
	for index := checker.layouts_checked; index < len(checker.nominals); index += 1 {
		nominal := checker.nominals[index]
		_, _, layout_err := types.layout(checker.store, nominal.type)
		if layout_err != .Recursive_Value { continue }
		entity := entity_get(scopes, nominal.entity)
		_, err := append(
			&checker.diagnostics,
			Type_Diagnostic {
				kind = .Recursive_Value,
				name = entity.name,
				source = {entity.declaration.file, entity.order.offset, entity.order.offset + u32(len(entity.name))},
			},
		)
		if err != nil { return err }
		entity.state = .Invalid
		entity.type = types.TYPE_POISON
	}
	checker.layouts_checked = len(checker.nominals)
	return nil
}

@(private = "file")
type_checker_sync :: proc(checker: ^Type_Checker) -> runtime.Allocator_Error {
	declarations := checker.collection.declarations
	for ; checker.synced < len(declarations); checker.synced += 1 {
		declaration := declarations[checker.synced]
		_, value, _, err := map_entry(&checker.declarations, declaration.entity)
		if err != nil { return err }
		value^ = declaration
	}
	return nil
}

@(private = "file")
type_alias_target :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	is_type: bool,
	err: Resolve_Error,
) {
	scopes := checker.resolver.scopes
	target := type_name_entity(checker, file, scope, node)
	if target == 0 { return false, nil }
	if entity_get(scopes, target).kind == .Constant {
		state := resolve_type_dependency(checker, target, type_node_span(file_id, file, node), .Name) or_return
		if state == .Invalid { return false, nil }
	}
	return entity_get(scopes, target).kind == .Type_Name, nil
}

// The entity a name in a type position refers to: a name in scope, or a member of an imported package.
@(private = "package")
type_name_entity :: proc(checker: ^Type_Checker, file: ^File, scope: Scope_Id, node: syntax.Node_Index) -> Entity_Id {
	if file.ast.nodes[node].kind == .Ident {
		target, _ := scope_lookup(checker.resolver.scopes, scope, type_node_text(file, node))
		return target
	}
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	package_scope, is_package := type_package_scope(checker, file, scope, selector.expr)
	if !is_package { return 0 }
	return scope_lookup_current(checker.resolver.scopes, package_scope, type_node_text(file, selector.field))
}

// The scope of the package that an import name binds. False when the qualifier is not an import name.
@(private = "file")
type_package_scope :: proc(checker: ^Type_Checker, file: ^File, scope: Scope_Id, qualifier: syntax.Node_Index) -> (package_scope: Scope_Id, found: bool) {
	if file.ast.nodes[qualifier].kind != .Ident { return 0, false }
	scopes := checker.resolver.scopes
	import_name, _ := scope_lookup(scopes, scope, type_node_text(file, qualifier))
	if import_name == 0 || entity_get(scopes, import_name).kind != .Import_Name { return 0, false }
	package_id := entity_get(scopes, import_name).data.(Import_Data).package_id
	if int(package_id) >= len(checker.packages) { return 0, false }
	return checker.packages[package_id].scope, true
}

@(private = "package")
publish_nominal :: proc(checker: ^Type_Checker, id: Entity_Id, kind: types.Kind, name: string) -> (type: types.Type_Id, err: runtime.Allocator_Error) {
	type = types.reserve_nominal(checker.store, kind, name)
	append(&checker.nominals, Nominal_Type{entity = id, type = type}) or_return
	entity_get(checker.resolver.scopes, id).type = type
	return type, nil
}

@(private = "file")
type_identifier :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
	direct: bool,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	scopes := checker.resolver.scopes
	name := type_node_text(file, node)
	found, _ := scope_lookup(scopes, scope, name)
	if found == 0 {
		type_report(checker, file_id, file, node, .Undeclared_Type, name) or_return
		return types.TYPE_POISON, nil
	}
	return type_of_entity(checker, file_id, file, node, found, direct)
}

// The type a type-name entity denotes. Its declaration is resolved first; poison is returned after a diagnostic.
@(private = "file")
type_of_entity :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	node: syntax.Node_Index,
	found: Entity_Id,
	direct: bool,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	kind := Dependency_Kind.Name
	if direct { kind = .Layout }
	state := resolve_type_dependency(checker, found, type_node_span(file_id, file, node), kind) or_return
	if state == .Invalid { return types.TYPE_POISON, nil }
	entity := entity_get(checker.resolver.scopes, found)
	if entity.kind != .Type_Name || entity.type == types.TYPE_NONE {
		type_report(checker, file_id, file, node, .Not_A_Type, type_node_text(file, node)) or_return
		return types.TYPE_POISON, nil
	}
	return entity.type, nil
}

// `pkg.Name` names a type that an imported package declares. Other selectors are values, not types.
@(private = "file")
type_selector :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
	direct: bool,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	if file.ast.nodes[selector.expr].kind == .Ident {
		qualifier, _ := scope_lookup(checker.resolver.scopes, scope, type_node_text(file, selector.expr))
		if qualifier == 0 {
			type_report(checker, file_id, file, selector.expr, .Undeclared_Type, type_node_text(file, selector.expr)) or_return
			return types.TYPE_POISON, nil
		}
	}
	package_scope, is_package := type_package_scope(checker, file, scope, selector.expr)
	if !is_package {
		type_report(checker, file_id, file, node, .Not_A_Type, type_node_text(file, node)) or_return
		return types.TYPE_POISON, nil
	}
	member := scope_lookup_current(checker.resolver.scopes, package_scope, type_node_text(file, selector.field))
	if member == 0 {
		type_report(checker, file_id, file, selector.field, .Undeclared_Type, type_node_text(file, selector.field)) or_return
		return types.TYPE_POISON, nil
	}
	return type_of_entity(checker, file_id, file, node, member, direct)
}

// `type_of(x)` declares a type name, as it does in a type position.
is_type_of_call :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	if file.ast.nodes[node].kind != .Call_Expr { return false }
	call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
	return file.ast.nodes[call.expr].kind == .Ident && type_node_text(file, call.expr) == "type_of"
}

// `type_of(x)` in a type position is the type of the identifier `x`.
@(private = "file")
type_of_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
	arguments := syntax.node_list(file.ast, call.args)
	if file.ast.nodes[call.expr].kind != .Ident ||
	   type_node_text(file, call.expr) != "type_of" ||
	   len(arguments) != 1 ||
	   file.ast.nodes[arguments[0]].kind != .Ident {
		type_report(checker, file_id, file, node, .Unsupported_Type_Expression) or_return
		return types.TYPE_POISON, nil
	}
	name := type_node_text(file, arguments[0])
	scopes := checker.resolver.scopes
	found, _ := scope_lookup(scopes, scope, name)
	if found == 0 {
		type_report(checker, file_id, file, arguments[0], .Undeclared_Type, name) or_return
		return types.TYPE_POISON, nil
	}
	state, resolve_error := resolve_entity(checker.resolver, found)
	if resolve_error != nil { return types.TYPE_POISON, resolve_error }
	if state == .Invalid { return types.TYPE_POISON, nil }
	return entity_get(scopes, found).type, nil
}

@(private = "package")
resolve_type_dependency :: proc(
	checker: ^Type_Checker,
	target: Entity_Id,
	source: Source_Span,
	kind: Dependency_Kind,
) -> (
	state: Resolution_State,
	err: Resolve_Error,
) {
	if len(checker.resolver.stack) == 0 { return resolve_entity(checker.resolver, target, .Type_Identity) }
	return resolve_dependency(checker.resolver, Dependency{entity = target, kind = kind, source = source}, .Type_Identity)
}

@(private = "file")
type_wrapper :: proc(checker: ^Type_Checker, kind: types.Kind, elem: types.Type_Id) -> types.Type_Id {
	if elem == types.TYPE_POISON { return types.TYPE_POISON }
	return types.intern(checker.store, types.Type{kind = kind, elem = elem})
}

@(private = "file")
array_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	array := syntax.node_payload(file.ast, node, syntax.Array_Type)
	if array.tag != 0 {
		tag := expression_text(file, array.tag)
		if tag == "#simd" { return simd_array_type(checker, file_id, file, scope, array) }
		if tag != "#sparse" {
			type_report(checker, file_id, file, array.tag, .Unsupported_Type_Expression, tag) or_return
			return types.TYPE_POISON, nil
		}
	}
	if array.len == 0 {
		elem := type_expression(checker, file_id, scope, array.elem, false) or_return
		return type_wrapper(checker, .Slice, elem), nil
	}
	length := type_unparen(file, array.len)
	if file.ast.nodes[length].kind == .Poly_Type {
		length = syntax.node_payload(file.ast, length, syntax.Poly_Type).type
	}
	if file.ast.nodes[length].kind == .Unary_Expr && syntax.node_payload(file.ast, length, syntax.Unary_Expr).op.kind == .Question {
		type_report(checker, file_id, file, length, .Invalid_Array_Count) or_return
		return types.TYPE_POISON, nil
	}
	if file.ast.nodes[length].kind == .Ident {
		sparse := array.tag != 0 && expression_text(file, array.tag) == "#sparse"
		if target, _ := scope_lookup(checker.resolver.scopes, scope, type_node_text(file, length));
		   target != 0 && entity_get(checker.resolver.scopes, target).kind == .Type_Name {
			return enumerated_array_type(checker, file_id, file, scope, array, length, sparse)
		}
	}
	count, count_valid := array_count(checker, file_id, scope, length) or_return
	elem := type_expression(checker, file_id, scope, array.elem, true) or_return
	if !count_valid || elem == types.TYPE_POISON { return types.TYPE_POISON, nil }
	return types.intern(checker.store, types.Type{kind = .Array, elem = elem, count = count}), nil
}

@(private = "file")
enumerated_array_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	array: syntax.Array_Type,
	length: syntax.Node_Index,
	sparse: bool,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	index := type_expression(checker, file_id, scope, length, false) or_return
	elem := type_expression(checker, file_id, scope, array.elem, true) or_return
	if index == types.TYPE_POISON || elem == types.TYPE_POISON { return types.TYPE_POISON, nil }
	descriptor := types.get(checker.store, underlying_type(checker.store, index))
	if descriptor.kind != .Enum {
		type_report(checker, file_id, file, length, .Invalid_Array_Count) or_return
		return types.TYPE_POISON, nil
	}
	count := i64(0)
	lower_bound := i64(0)
	if descriptor.count > 0 {
		count = descriptor.upper_bound - descriptor.lower_bound + 1
		lower_bound = descriptor.lower_bound
	}
	if count > descriptor.count && !sparse {
		type_report(checker, file_id, file, length, .Non_Contiguous_Enum_Index) or_return
		return types.TYPE_POISON, nil
	}
	return types.intern(
			checker.store,
			types.Type{kind = .Enumerated_Array, elem = elem, index = index, count = count, lower_bound = lower_bound, sparse = sparse},
		),
		nil
}

array_count :: proc(checker: ^Type_Checker, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> (count: i64, valid: bool, err: Resolve_Error) {
	file := checker.files[file_id]
	value, ok := integer_expression(checker, file_id, file, scope, node) or_return
	if ok && value < 0 {
		type_report(checker, file_id, file, node, .Invalid_Array_Count) or_return
		return 0, false, nil
	}
	return value, ok, nil
}

integer_expression :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	value: i64,
	ok: bool,
	err: Resolve_Error,
) {
	if checker.evaluate_integer == nil {
		type_report(checker, file_id, file, node, .Missing_Evaluator) or_return
		return 0, false, nil
	}
	return checker.evaluate_integer(checker, scope, file_id, node, checker.user_data)
}

@(private = "file")
alignment_expression :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	alignment: i64,
	valid: bool,
	err: Resolve_Error,
) {
	if node == 0 { return 0, true, nil }
	value, ok := integer_expression(checker, file_id, file, scope, node) or_return
	if !ok { return 0, false, nil }
	if value <= 0 || value & (value - 1) != 0 {
		type_report(checker, file_id, file, node, .Invalid_Alignment) or_return
		return 0, false, nil
	}
	return value, true, nil
}

@(private = "package")
struct_descriptor :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
	name: string,
) -> (
	descriptor: types.Type,
	flags: []syntax.Field_Flags,
	valid: bool,
	err: Resolve_Error,
) {
	record := syntax.node_payload(file.ast, node, syntax.Struct_Type)
	valid = true
	if record.poly_params != 0 && checker.record_instance == 0 || record.poly_params == 0 && record.where_clauses.count != 0 {
		type_report(checker, file_id, file, node, .Unsupported_Type_Expression) or_return
		valid = false
	}
	fields, fields_valid, _, field_flags := record_fields(checker, file_id, file, scope, record.fields, true, true) or_return
	if fields_valid && !(struct_using_fields_valid(checker, fields, field_flags) or_return) {
		type_report(checker, file_id, file, node, .Duplicate_Field) or_return
		fields_valid = false
	}
	descriptor = types.Type {
		kind      = .Struct,
		name      = name,
		fields    = fields,
		packed    = .Packed in record.flags,
		raw_union = .Raw_Union in record.flags,
	}
	align_valid, min_valid, max_valid: bool
	descriptor.custom_align, align_valid = alignment_expression(checker, file_id, file, scope, record.align) or_return
	descriptor.min_field_align, min_valid = alignment_expression(checker, file_id, file, scope, record.min_field_align) or_return
	descriptor.max_field_align, max_valid = alignment_expression(checker, file_id, file, scope, record.max_field_align) or_return
	return descriptor, field_flags, valid && fields_valid && align_valid && min_valid && max_valid, nil
}

@(private = "package")
union_descriptor :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
	name: string,
) -> (
	descriptor: types.Type,
	valid: bool,
	err: Resolve_Error,
) {
	record := syntax.node_payload(file.ast, node, syntax.Union_Type)
	valid = true
	if record.poly_params != 0 && checker.record_instance == 0 || record.poly_params == 0 && record.where_clauses.count != 0 {
		type_report(checker, file_id, file, node, .Unsupported_Type_Expression) or_return
		valid = false
	}
	nodes := syntax.node_list(file.ast, record.variants)
	variants := make([]types.Type_Id, len(nodes), checker.arena_allocator) or_return
	for variant_node, index in nodes {
		variants[index] = type_expression(checker, file_id, scope, variant_node, true) or_return
		if variants[index] == types.TYPE_POISON {
			valid = false
			continue
		}
		for previous in variants[:index] {
			if previous == variants[index] {
				type_report(checker, file_id, file, variant_node, .Duplicate_Variant) or_return
				valid = false
				break
			}
		}
	}
	descriptor = types.Type {
		kind       = .Union,
		name       = name,
		variants   = variants,
		union_form = .Tagged,
	}
	switch record.kind {
	case .Normal, .Maybe:
		if len(variants) == 1 && variants[0] != types.TYPE_POISON {
			#partial switch types.get(checker.store, variants[0]).kind {
			case .Pointer, .Multi_Pointer, .Raw_Pointer, .Procedure:
				descriptor.union_form = .Maybe_Pointer
			}
		}
	case .No_Nil:
		descriptor.union_form = .No_Nil
	case .Shared_Nil:
		descriptor.union_form = .Shared_Nil
	}
	align_valid: bool
	descriptor.custom_align, align_valid = alignment_expression(checker, file_id, file, scope, record.align) or_return
	return descriptor, valid && align_valid, nil
}

@(private = "file")
enum_descriptor :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
	name: string,
) -> (
	descriptor: types.Type,
	members: []Enum_Member,
	valid: bool,
	err: Resolve_Error,
) {
	record := syntax.node_payload(file.ast, node, syntax.Enum_Type)
	enum_scope, scope_error := scope_create(checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return {}, nil, false, binding_resolve_error(scope_error) }
	valid = true
	base := types.intern(checker.store, types.Type{kind = .Integer, name = "int", count = types.DEFAULT_LAYOUT.int_size, signed = true})
	if record.base_type != 0 {
		base = type_expression(checker, file_id, scope, record.base_type, true) or_return
		if base == types.TYPE_POISON {
			valid = false
		} else if underlying := types.get(checker.store, underlying_type(checker.store, base)); underlying.kind != .Integer || underlying.count > 8 {
			type_report(checker, file_id, file, record.base_type, .Invalid_Enum_Base) or_return
			valid = false
		}
	}
	nodes := syntax.node_list(file.ast, record.fields)
	members = make([]Enum_Member, len(nodes), checker.arena_allocator) or_return
	count := 0
	next, lower, upper := i64(0), i64(0), i64(0)
	for member_node in nodes {
		name_node, value_node := member_node, syntax.Node_Index(0)
		if file.ast.nodes[member_node].kind == .Field_Value {
			field := syntax.node_payload(file.ast, member_node, syntax.Field_Value)
			name_node, value_node = field.field, field.value
		}
		if file.ast.nodes[name_node].kind != .Ident {
			type_report(checker, file_id, file, name_node, .Invalid_Name) or_return
			valid = false
			continue
		}
		member_name := type_node_text(file, name_node)
		value := next
		if value_node != 0 {
			evaluated, ok := integer_expression(checker, file_id, file, enum_scope, value_node) or_return
			if !ok {
				valid = false
				continue
			}
			value = evaluated
		}
		if valid && !integer_fits(types.get(checker.store, underlying_type(checker.store, base)), value) {
			type_report(checker, file_id, file, member_node, .Enum_Value_Out_Of_Range, member_name) or_return
			valid = false
		}
		if member_name != "_" {
			for previous in members[:count] {
				if previous.name == member_name {
					type_report(checker, file_id, file, name_node, .Duplicate_Enum_Member, member_name) or_return
					valid = false
					break
				}
			}
		}
		members[count] = Enum_Member {
			name   = member_name,
			value  = value,
			source = type_node_span(file_id, file, name_node),
		}
		if member_name != "_" && checker.bind_enum_member != nil {
			checker.bind_enum_member(checker, enum_scope, file_id, member_name, value, base, value_node, checker.user_data) or_return
		}
		if count == 0 || value < lower { lower = value }
		if count == 0 || value > upper { upper = value }
		count += 1
		next = value + 1
	}
	members = members[:count]
	descriptor = types.Type {
		kind        = .Enum,
		name        = name,
		backing     = base,
		count       = i64(count),
		lower_bound = lower,
		upper_bound = upper,
	}
	return descriptor, members, valid, nil
}

// Records each field's flags (`using`, `#subtype`), aligned with the descriptor fields, when any field has flags.
@(private = "package")
register_field_flags :: proc(checker: ^Type_Checker, type: types.Type_Id, field_flags: []syntax.Field_Flags) -> runtime.Allocator_Error {
	any_flagged := false
	for flags in field_flags { any_flagged ||= flags != {} }
	if !any_flagged { return nil }
	_, stored, inserted, err := map_entry(&checker.field_flags, type)
	if err != nil { return err }
	if inserted { stored^ = field_flags }
	return nil
}

@(private = "file")
register_enum :: proc(checker: ^Type_Checker, type: types.Type_Id, members: []Enum_Member) -> runtime.Allocator_Error {
	_, stored, inserted, err := map_entry(&checker.enum_members, type)
	if err != nil { return err }
	if inserted { stored^ = members }
	return nil
}

@(private = "file")
procedure_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	signature := syntax.node_payload(file.ast, node, syntax.Proc_Type)
	if signature.generic && !checker.instantiating {
		type_report(checker, file_id, file, node, .Unsupported_Type_Expression) or_return
		return types.TYPE_POISON, nil
	}
	convention := types.Calling_Convention.Odin
	if signature.foreign_default { convention = .C }
	if signature.calling_convention != 0 {
		literal := type_node_text(file, signature.calling_convention)
		text, allocated, unquoted := strconv.unquote_string(literal, checker.arena_allocator)
		_ = allocated
		known: bool
		if unquoted { convention, known = calling_convention_from_name(text) }
		if !unquoted || !known {
			type_report(checker, file_id, file, signature.calling_convention, .Invalid_Calling_Convention) or_return
			return types.TYPE_POISON, nil
		}
	}
	c_vararg := false
	if signature.params != 0 {
		for parameter in syntax.node_list(file.ast, syntax.node_payload(file.ast, signature.params, syntax.Field_List).list) {
			if .C_Vararg in syntax.node_payload(file.ast, parameter, syntax.Field).flags {
				if convention == .Odin || convention == .Contextless {
					type_report(checker, file_id, file, parameter, .Invalid_Calling_Convention) or_return
					return types.TYPE_POISON, nil
				}
				c_vararg = true
			}
		}
	}
	parameters, parameters_valid, variadic, _ := record_fields(checker, file_id, file, scope, signature.params, false, false) or_return
	results, results_valid, _, _ := record_fields(checker, file_id, file, scope, signature.results, false, false) or_return
	if !parameters_valid || !results_valid { return types.TYPE_POISON, nil }
	parameter_types := make([]types.Type_Id, len(parameters), checker.arena_allocator) or_return
	result_types := make([]types.Type_Id, len(results), checker.arena_allocator) or_return
	for parameter, index in parameters { parameter_types[index] = parameter.type }
	for result, index in results { result_types[index] = result.type }
	optional_ok := .Optional_Ok in signature.tags
	optional_allocator := .Optional_Allocator_Error in signature.tags
	if optional_ok && optional_allocator || (optional_ok || optional_allocator) && !optional_result_valid(checker, result_types, optional_allocator) {
		type_report(checker, file_id, file, signature.results, .Invalid_Optional_Result) or_return
		return types.TYPE_POISON, nil
	}
	optional_result := optional_ok || optional_allocator
	return types.intern(
			checker.store,
			types.Type {
				kind = .Procedure,
				params = parameter_types,
				results = result_types,
				convention = convention,
				variadic = variadic,
				c_vararg = c_vararg,
				optional_result = optional_result,
				diverging = signature.diverging,
			},
		),
		nil
}

// Checks the default expression of an untyped parameter and takes its default type, as official handle_parameter_value does.
@(private = "package")
default_expression_type :: proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file_id: File_Id,
	value: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	found: bool,
	err: Resolve_Error,
) {
	if checker.evaluate_default_type == nil { return 0, false, nil }
	inferred, ok, evaluate_error := checker.evaluate_default_type(checker, scope, file_id, value, checker.user_data)
	if evaluate_error != nil { return 0, false, evaluate_error }
	if !ok { return types.TYPE_POISON, true, nil }
	return inferred, true, nil
}

// An untyped parameter takes the type of its default: `#caller_location` and `#caller_expression` are strings and locations, literals take their default type.
@(private = "package")
default_parameter_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	value: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	found: bool,
	err: Resolve_Error,
) {
	if value == 0 { return 0, false, nil }
	if file.ast.nodes[value].kind == .Basic_Lit {
		untyped: types.Type_Id
		#partial switch syntax.node_payload(file.ast, value, syntax.Basic_Lit).kind {
		case .Integer:
			untyped = types.TYPE_UNTYPED_INTEGER
		case .Float:
			untyped = types.TYPE_UNTYPED_FLOAT
		case .Rune:
			untyped = types.TYPE_UNTYPED_RUNE
		case .String:
			return types.intern(checker.store, types.Type{kind = .String}), true, nil
		case:
			return 0, false, nil
		}
		return types.default_type_of_untyped(checker.store, untyped), true, nil
	}
	directive := value
	if file.ast.nodes[value].kind == .Call_Expr { directive = syntax.node_payload(file.ast, value, syntax.Call_Expr).expr }
	if file.ast.nodes[directive].kind != .Basic_Directive { return default_expression_type(checker, scope, file_id, value) }
	switch expression_text(file, directive) {
	case "#caller_expression":
		return types.intern(checker.store, types.Type{kind = .String}), true, nil
	case "#caller_location":
		if directive != value || checker.collection.runtime_scope == 0 { return 0, false, nil }
		entity := scope_lookup_current(checker.resolver.scopes, checker.collection.runtime_scope, "Source_Code_Location")
		if entity == 0 { return 0, false, nil }
		if _, resolve_error := resolve_entity(checker.resolver, entity); resolve_error != nil { return 0, false, resolve_error }
		return entity_get(checker.resolver.scopes, entity).type, true, nil
	}
	return 0, false, nil
}

// Parameters and results keep an empty name when unnamed; a trailing `..T` becomes a slice and sets variadic.
@(private = "file")
record_fields :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	list_node: syntax.Node_Index,
	direct, unique_names: bool,
) -> (
	fields: []types.Type_Field,
	valid: bool,
	variadic: bool,
	field_flags: []syntax.Field_Flags,
	err: Resolve_Error,
) {
	if list_node == 0 { return nil, true, false, nil, nil }
	nodes := syntax.node_list(file.ast, syntax.node_payload(file.ast, list_node, syntax.Field_List).list)
	total := 0
	for field_node in nodes { total += max(int(syntax.node_payload(file.ast, field_node, syntax.Field).names.count), 1) }
	stored := make([]types.Type_Field, total, checker.arena_allocator) or_return
	flags := make([]syntax.Field_Flags, total, checker.arena_allocator) or_return
	count := 0
	valid = true
	for field_node in nodes {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		if checker.instantiating && is_poly_name_field(file, field) { continue }
		type_node := field.type
		is_variadic := false
		if type_node != 0 && file.ast.nodes[type_node].kind == .Ellipsis {
			is_variadic = true
			type_node = syntax.node_payload(file.ast, type_node, syntax.Ellipsis).expr
		}
		field_type := types.TYPE_POISON
		if type_node == 0 {
			inferred, found := default_parameter_type(checker, file_id, file, scope, field.default_value) or_return
			if found {
				field_type = inferred
			} else {
				type_report(checker, file_id, file, field_node, .Missing_Field_Type) or_return
			}
		} else {
			field_type = type_expression(checker, file_id, scope, type_node, direct) or_return
			if is_variadic { field_type = type_wrapper(checker, .Slice, field_type) }
		}
		if field_type == types.TYPE_POISON { valid = false }
		if is_variadic { variadic = true }
		names := syntax.node_list(file.ast, field.names)
		if len(names) == 0 {
			stored[count] = types.Type_Field {
				type = field_type,
			}
			count += 1
		}
		for name_node in names {
			if file.ast.nodes[name_node].kind != .Ident {
				type_report(checker, file_id, file, name_node, .Invalid_Name) or_return
				valid = false
				continue
			}
			field_name := type_node_text(file, name_node)
			if unique_names && field_name != "_" {
				for previous in stored[:count] {
					if previous.name == field_name {
						type_report(checker, file_id, file, name_node, .Duplicate_Field, field_name) or_return
						valid = false
						break
					}
				}
			}
			stored[count] = types.Type_Field {
				name = field_name,
				type = field_type,
			}
			flags[count] = field.flags
			count += 1
		}
	}
	return stored[:count], valid, variadic, flags[:count], nil
}

@(private = "file")
calling_convention_from_name :: proc(name: string) -> (convention: types.Calling_Convention, ok: bool) {
	switch name {
	case "odin":
		return .Odin, true
	case "contextless":
		return .Contextless, true
	case "c", "cdecl":
		return .C, true
	case "stdcall", "std":
		return .Stdcall, true
	case "fastcall", "fast":
		return .Fastcall, true
	case "win64":
		return .Win64, true
	case "sysv":
		return .SysV, true
	case "preserve/none":
		return .Preserve_None, true
	case "preserve/most":
		return .Preserve_Most, true
	case "preserve/all":
		return .Preserve_All, true
	}
	return .Odin, false
}

underlying_type :: proc(store: ^types.Store, id: types.Type_Id) -> types.Type_Id {
	current := id
	for _ in 0 ..< len(store.types) {
		descriptor := types.get(store, current)
		if descriptor.kind != .Named || descriptor.elem == types.TYPE_NONE { break }
		current = descriptor.elem
	}
	return current
}

@(private = "file")
integer_fits :: proc(integer: ^types.Type, value: i64) -> bool {
	bits := u64(integer.count) * 8
	if bits >= 64 { return integer.signed || value >= 0 }
	if integer.signed {
		limit := i64(1) << (bits - 1)
		return -limit <= value && value < limit
	}
	return 0 <= value && value < i64(1) << bits
}

@(private = "package")
type_unparen :: proc(file: ^File, node: syntax.Node_Index) -> syntax.Node_Index {
	node := node
	for node != 0 && file.ast.nodes[node].kind == .Paren_Expr { node = syntax.node_payload(file.ast, node, syntax.Paren_Expr).expr }
	return node
}

@(private = "package")
type_node_text :: proc(file: ^File, node: syntax.Node_Index) -> string {
	span := file.ast.nodes[node]
	return string(file.source[span.start:span.end])
}

@(private = "package")
type_node_span :: proc(file_id: File_Id, file: ^File, node: syntax.Node_Index) -> Source_Span {
	span := file.ast.nodes[node]
	return {file_id, span.start, span.end}
}

type_report :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	node: syntax.Node_Index,
	kind: Type_Diagnostic_Kind,
	name := "",
) -> runtime.Allocator_Error {
	_, err := append(&checker.diagnostics, Type_Diagnostic{kind = kind, name = name, source = type_node_span(file_id, file, node)})
	return err
}
