package check

import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_using_statement :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	if !using_statement_enabled(file) {
		_, err := expression_failure(checker, view, scope, node, .Invalid_Operand, "Using_Disallowed")
		return err
	}
	scopes := checker.type_checker.resolver.scopes
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	for operand in syntax.node_list(file.ast, syntax.node_payload(file.ast, node, syntax.Using_Stmt).list) {
		root := type_unparen(file, operand)
		if file.ast.nodes[root].kind != .Ident && file.ast.nodes[root].kind != .Selector_Expr {
			_, err := expression_failure(checker, view, scope, operand, .Invalid_Operand, "Using_Entity")
			return err
		}
		if file.ast.nodes[root].kind == .Ident {
			entity, _ := scope_lookup(scopes, scope, expression_text(file, root))
			if entity != 0 && entity_get(scopes, entity).kind == .Import_Name {
				package_id := entity_get(scopes, entity).data.(Import_Data).package_id
				members := scope_get(scopes, checker.packages[package_id].scope).lookup
				for name, member in members {
					if .Private_File in entity_get(scopes, member).flags || .Private_Package in entity_get(scopes, member).flags { continue }
					previous, insert_error := scope_insert_with_name(scopes, scope, name, member)
					if insert_error != nil { return binding_resolve_error(insert_error) }
					if previous != 0 { return using_collision(checker, view, scope, operand) }
				}
				continue
			}
		}
		base := check_expression(checker, view, scope, root) or_return
		if base.state == .Invalid { continue }
		owner := types.resolve_named(store, base.type)
		indirect := types.get(store, owner).kind == .Pointer
		if indirect { owner = types.resolve_named(store, types.get(store, owner).elem) }
		descriptor := types.get(store, owner)^
		if base.mode == .Type && descriptor.kind == .Enum {
			for member in checker.type_checker.enum_members[owner] {
				repeated := false
				for binding in scope_get(scopes, scope).using_bindings {
					if binding.origin == base.entity && binding.name == member.name && len(binding.path) == 0 { repeated = true; break }
				}
				if repeated { continue }
				value := expression_enum_member(checker, view, scope, operand, base.type, member.name) or_return
				entity, create_error := entity_create(
					scopes,
					Entity{name = member.name, kind = .Constant, scope = scope, state = .Resolved, type = base.type, constant = value.constant},
				)
				if create_error != nil { return binding_resolve_error(create_error) }
				previous, insert_error := scope_insert(scopes, scope, entity)
				if insert_error != nil { return binding_resolve_error(insert_error) }
				if previous != 0 { return using_collision(checker, view, scope, operand) }
				store_using_binding(checker, scope, Using_Binding{name = member.name, entity = entity, origin = base.entity}) or_return
			}
			continue
		}
		if descriptor.kind != .Struct || base.mode != .Variable && base.mode != .Immutable_Value && base.mode != .Value && base.mode != .Soa_Variable {
			_, err := expression_failure(checker, view, scope, operand, .Invalid_Operand, "Using_Struct_Variable")
			return err
		}
		names := make([dynamic]string, allocator) or_return
		defer delete(names)
		using_struct_fields(checker, view, scope, operand, base, Operand(Expression_Ref{view, root}), owner, indirect, nil, &names) or_return
	}
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "file")
using_collision :: proc(checker: ^Expression_Checker, view: View_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	_, err := expression_failure(checker, view, scope, node, .Invalid_Operand, "Using_Collision")
	return err
}

@(private = "package")
expression_using_binding :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	binding: Using_Binding,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file_id := checker.views[view].file
	info = expression_entity_info(checker, file_id, scope, node, binding.entity) or_return
	if info.state == .Invalid { return info, nil }
	if len(binding.path) == 0 { return info, nil }
	// A field promoted from an #soa element addresses its spread lane
	// directly through the element's Soa_Plan. Deeper paths keep the
	// Place_Plan over a gathered copy.
	if len(binding.path) == 1 {
		if root, is_reference := binding.root.(Expression_Ref); is_reference {
			// Re-reading the root is idempotent for identifiers and
			// selectors and returns its plan-carrying info.
			root_info := check_expression(checker, root.view, scope, root.node) or_return
			if root_info.state != .Invalid && root_info.plan != 0 {
				if whole, is_soa := checker.plans[root_info.plan].(Soa_Plan); is_soa && whole.field == nil {
					field: Operand
					field, err = using_soa_field(checker, file_id, node, int(binding.path[0].field_index))
					if err != nil { return info, err }
					plan := Plan_Id(len(checker.plans))
					append(
						&checker.plans,
						Plan(Soa_Plan{container = whole.container, index = whole.index, field = field, soa = whole.soa, policy = whole.policy}),
					) or_return
					info.entity = 0
					info.plan = plan
					return info, nil
				}
			}
		}
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Place_Plan{root = binding.root, path = binding.path})) or_return
	info.entity = 0
	info.plan = plan
	return info, nil
}

// Interns a constant spread-field index for an #soa using binding.
@(private = "file")
using_soa_field :: proc(checker: ^Expression_Checker, file_id: File_Id, node: syntax.Node_Index, field: int) -> (operand: Operand, err: Resolve_Error) {
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, i64(field)); set_error != nil {
		expression_constant_failure(checker, file_id, node, set_error) or_return
		return nil, nil
	}
	field_id, intern_error := constant_pool_intern_integer(checker.constants, &value, types.TYPE_UNTYPED_INTEGER)
	if intern_error != nil {
		expression_constant_failure(checker, file_id, node, intern_error) or_return
		return nil, nil
	}
	return Operand(field_id), nil
}

@(private = "file")
using_statement_enabled :: proc(file: ^File) -> bool {
	for feature in file.policy.features {
		if feature == "using-stmt" { return true }
	}
	return false
}

@(private = "package")
expression_using_parameter :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	parameter: Entity_Id,
) -> Resolve_Error {
	file := checker.type_checker.files[checker.views[view].file]
	if !using_statement_enabled(file) {
		_, err := expression_failure(checker, view, scope, node, .Invalid_Operand, "Using_Disallowed")
		return err
	}
	entity := entity_get(checker.type_checker.resolver.scopes, parameter)^
	if entity.name == "_" || entity.name == "" {
		_, err := expression_failure(checker, view, scope, node, .Invalid_Operand, "Using_Parameter_Name")
		return err
	}
	store := checker.type_checker.store
	owner := types.resolve_named(store, entity.type)
	indirect := types.get(store, owner).kind == .Pointer
	if indirect { owner = types.resolve_named(store, types.get(store, owner).elem) }
	if types.get(store, owner).kind != .Struct {
		_, err := expression_failure(checker, view, scope, node, .Invalid_Operand, "Using_Struct_Variable")
		return err
	}
	names := make([dynamic]string, mem.dynamic_arena_allocator(&checker.arena)) or_return
	defer delete(names)
	base := Expression_Info {
		type   = entity.type,
		mode   = .Immutable_Value,
		entity = parameter,
		scope  = scope,
		state  = .Checked,
	}
	return using_struct_fields(checker, view, scope, node, base, Operand(parameter), owner, indirect, nil, &names)
}

@(private = "file")
using_struct_fields :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	base: Expression_Info,
	root: Operand,
	owner: types.Type_Id,
	indirect: bool,
	prefix: []Member_Step,
	names: ^[dynamic]string,
) -> Resolve_Error {
	for step in prefix { if step.type == owner { return nil } }
	scopes := checker.type_checker.resolver.scopes
	store := checker.type_checker.store
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	fields := types.get(store, owner).fields
	for field, index in fields {
		if field.name == "_" { continue }
		seen := false
		for name in names { if name == field.name { seen = true; break } }
		if seen { return using_collision(checker, view, scope, node) }
		append(names, field.name) or_return
		flags: Entity_Flags
		root_indirect := indirect
		if len(prefix) != 0 { root_indirect = prefix[0].indirect }
		// An #soa loop variable reports .Soa_Variable whether it binds by
		// value or by reference; its entity flags tell the two apart.
		root_mutable := base.mode == .Variable
		if base.mode == .Soa_Variable {
			if origin := entity_get(scopes, base.entity); origin != nil {
				root_mutable = .Immutable not_in origin.flags
			}
		}
		if !root_indirect && !root_mutable { flags += {.Immutable} }
		if origin := entity_get(scopes, base.entity); origin != nil && .Parameter in origin.flags { flags += {.Parameter, .Using} }
		entity, create_error := entity_create(
			scopes,
			Entity {
				name = field.name,
				kind = .Variable,
				scope = scope,
				state = .Resolved,
				flags = flags,
				type = field.type,
				data = Variable_Data{storage = .Local},
			},
		)
		if create_error != nil { return binding_resolve_error(create_error) }
		previous, insert_error := scope_insert(scopes, scope, entity)
		if insert_error != nil { return binding_resolve_error(insert_error) }
		if previous != 0 { return using_collision(checker, view, scope, node) }
		path := make([]Member_Step, len(prefix) + 1, allocator) or_return
		copy(path, prefix)
		path[len(prefix)] = {
			type        = owner,
			field_index = u32(index),
			indirect    = indirect,
		}
		binding := Using_Binding {
			name   = field.name,
			entity = entity,
			origin = base.entity,
			root   = root,
			path   = path,
		}
		store_using_binding(checker, scope, binding) or_return
	}
	field_flags := checker.type_checker.field_flags[owner]
	for field, index in fields {
		if index >= len(field_flags) || .Using not_in field_flags[index] { continue }
		embedded := types.resolve_named(store, field.type)
		embedded_indirect := types.get(store, embedded).kind == .Pointer
		if embedded_indirect { embedded = types.resolve_named(store, types.get(store, embedded).elem) }
		if types.get(store, embedded).kind != .Struct { continue }
		path := make([]Member_Step, len(prefix) + 1, allocator) or_return
		copy(path, prefix)
		path[len(prefix)] = {
			type        = owner,
			field_index = u32(index),
			indirect    = indirect,
		}
		using_struct_fields(checker, view, scope, node, base, root, embedded, embedded_indirect, path, names) or_return
	}
	return nil
}

@(private = "file")
store_using_binding :: proc(checker: ^Expression_Checker, scope: Scope_Id, binding: Using_Binding) -> Resolve_Error {
	scopes := checker.type_checker.resolver.scopes
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	bindings := make([]Using_Binding, len(scope_get(scopes, scope).using_bindings) + 1, allocator) or_return
	copy(bindings, scope_get(scopes, scope).using_bindings)
	bindings[len(bindings) - 1] = binding
	scope_get(scopes, scope).using_bindings = bindings
	return nil
}
