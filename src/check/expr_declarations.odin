package check

import "base:runtime"
import "core:math/big"
import "oc:syntax"
import "oc:types"

// Install as Type_Checker.evaluate_integer with the Expression_Checker as its user_data.
expression_integer_evaluator :: proc(
	type_checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	node: syntax.Node_Index,
	user_data: rawptr,
) -> (
	value: i64,
	ok: bool,
	err: Resolve_Error,
) {
	checker := cast(^Expression_Checker)user_data
	assert(checker != nil && checker.type_checker == type_checker)
	view := expression_file_view(checker, file) or_return
	info := check_expression(checker, view, scope, node) or_return
	if info.state == .Invalid { return }
	if info.mode == .Constant && conversion_integer(types.get(type_checker.store, conversion_base_type(type_checker.store, info.type)).kind) {
		constant := constant_pool_get(checker.constants, info.constant)
		if integer, is_integer := constant.value.(big.Int); is_integer {
			converted, failure := big.int_get_i64(&integer, allocator = checker.allocator)
			if failure == .None { return converted, true, nil }
			if failure == .Out_Of_Memory { return 0, false, runtime.Allocator_Error.Out_Of_Memory }
		}
	}
	expression_failure(checker, view, scope, node, .Expected_Integer_Constant) or_return
	return 0, false, nil
}

expression_enum_member_binder :: proc(
	type_checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	name: string,
	value: i64,
	backing: types.Type_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> Resolve_Error {
	checker := cast(^Expression_Checker)user_data
	assert(checker != nil && checker.type_checker == type_checker)
	constant: Const_Id
	if expression != 0 {
		view := expression_file_view(checker, file) or_return
		info := check_expression(checker, view, scope, expression) or_return
		if info.state == .Invalid || info.mode != .Constant { return nil }
		constant = info.constant
	} else {
		integer: big.Int
		defer big.destroy(&integer)
		if failure := big.set(&integer, value); failure != nil {
			expression_constant_failure(checker, file, 0, failure) or_return
			return nil
		}
		failure: Constant_Error
		constant, failure = constant_pool_intern_integer(checker.constants, &integer, backing)
		if failure != nil {
			expression_constant_failure(checker, file, 0, failure) or_return
			return nil
		}
	}
	entity, create_error := entity_create(
		type_checker.resolver.scopes,
		Entity{name = name, kind = .Constant, scope = scope, state = .Resolved, type = backing, constant = constant},
	)
	if create_error != nil { return binding_resolve_error(create_error) }
	_, insert_error := scope_insert(type_checker.resolver.scopes, scope, entity)
	if insert_error != nil { return binding_resolve_error(insert_error) }
	return nil
}

// Checks an untyped initializer against its default type; untyped constants are converted so their type is the default.
@(private = "package")
expression_check_default :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	target: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	info = check_expression(checker, view, scope, node, target) or_return
	info = check_expression(checker, view, scope, node, target) or_return
	if info.state == .Invalid || info.mode != .Constant { return info, nil }
	if !conversion_untyped(types.get(checker.type_checker.store, info.type).kind) { return info, nil }
	return expression_conversion(checker, view, scope, node, Operand(info.constant), info, target, .Assignment)
}

expression_type_evaluator :: proc(
	type_checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	node: syntax.Node_Index,
	user_data: rawptr,
) -> (
	type_id: types.Type_Id,
	err: Resolve_Error,
) {
	checker := cast(^Expression_Checker)user_data
	assert(checker != nil && checker.type_checker == type_checker)
	view := expression_file_view(checker, file) or_return
	info := check_expression(checker, view, scope, node) or_return
	if info.state == .Invalid { return types.TYPE_POISON, nil }
	if info.mode != .Type { return 0, nil }
	return info.type, nil
}

// Install as Type_Checker.evaluate_default_type with the Expression_Checker as its user_data.
expression_default_type_evaluator :: proc(
	type_checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	node: syntax.Node_Index,
	user_data: rawptr,
) -> (
	type_id: types.Type_Id,
	ok: bool,
	err: Resolve_Error,
) {
	checker := cast(^Expression_Checker)user_data
	assert(checker != nil && checker.type_checker == type_checker)
	view := expression_file_view(checker, file) or_return
	info := check_expression(checker, view, scope, node) or_return
	if info.state == .Invalid { return types.TYPE_POISON, false, nil }
	return types.default_type_of_untyped(checker.type_checker.store, info.type), true, nil
}

// Install as Type_Checker.evaluate_boolean with the Expression_Checker as its user_data.
expression_boolean_evaluator :: proc(
	type_checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	node: syntax.Node_Index,
	user_data: rawptr,
) -> (
	value: bool,
	ok: bool,
	err: Resolve_Error,
) {
	checker := cast(^Expression_Checker)user_data
	assert(checker != nil && checker.type_checker == type_checker)
	view := expression_file_view(checker, file) or_return
	poisoned := len(type_checker.resolver.poisoned)
	resolver_diagnostics := len(type_checker.resolver.diagnostics)
	checker_diagnostics := len(checker.diagnostics)
	type_diagnostics := len(type_checker.diagnostics)
	invalid_rows := len(checker.invalid_rows)
	info := check_expression(checker, view, scope, node) or_return
	if info.state == .Invalid {
		expression_rollback_invalid_rows(checker, invalid_rows)
		resolver_rollback_poison(type_checker.resolver, poisoned)
		resize(&type_checker.resolver.diagnostics, resolver_diagnostics)
		resize(&checker.diagnostics, checker_diagnostics)
		resize(&type_checker.diagnostics, type_diagnostics)
		return false, false, nil
	}
	if info.mode == .Constant {
		if constant, is_bool := constant_pool_get(checker.constants, info.constant).value.(bool); is_bool { return constant, true, nil }
	}
	expression_failure(checker, view, scope, node, .Expected_Boolean_Constant) or_return
	return false, false, nil
}

// Declaration dispatcher for the narrow scalar slice. Other declaration kinds remain unsupported.
// Type declarations are attempted first so aliases and constant-dependent layouts use one resolver.
expression_declaration :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	checker := cast(^Expression_Checker)user_data
	resolver.check_body = expression_procedure_body_declaration
	handled, type_valid := type_declaration(checker.type_checker, id) or_return
	if handled { return type_valid, nil }
	declaration, found := checker.type_checker.declarations[id]
	if !found { return false, nil }
	entity := entity_get(resolver.scopes, id)^
	view := expression_file_view(checker, declaration.identifier.file) or_return
	if entity.kind == .Procedure && expression_in_intrinsics(checker, entity.package_id) && entity.data.(Procedure_Data).body.node == 0 {
		return expression_intrinsic_declaration(checker, resolver, id, view, declaration.identifier.node)
	}
	if entity.kind == .Import_Name || entity.kind == .Library_Name { return true, nil }
	if entity.kind == .Procedure { return expression_procedure_declaration(checker, resolver, id, declaration, entity.scope) }
	if entity.kind == .Procedure_Group { return expression_procedure_group_declaration(checker, resolver, id, declaration, entity.scope) }
	if entity.kind != .Constant && entity.kind != .Variable {
		expression_unsupported(checker, view, entity.scope, declaration.identifier.node, "Declaration_Kind") or_return
		return false, nil
	}
	if entity.kind == .Constant && declaration.type.node == 0 && declaration.value.node != 0 {
		file := checker.type_checker.files[declaration.value.file]
		value := type_unparen(file, declaration.value.node)
		if file.ast.nodes[value].kind == .Ident {
			target, _ := scope_lookup(resolver.scopes, entity.scope, expression_text(file, value))
			if target != 0 && entity_get(resolver.scopes, target).kind == .Import_Name {
				imported := entity_get(resolver.scopes, target)^
				binding := entity_get(resolver.scopes, id)
				binding.kind, binding.data = .Import_Name, imported.data
				return true, nil
			}
		}
	}
	target := types.TYPE_NONE
	if declaration.type.node != 0 {
		target = type_expression(checker.type_checker, declaration.type.file, entity.scope, declaration.type.node, true) or_return
		if target == types.TYPE_POISON { return false, nil }
	}
	info: Expression_Info
	if declaration.value.node != 0 {
		info = check_expression(checker, view, entity.scope, declaration.value.node, target) or_return
		if info.state == .Invalid { return false, nil }
		if entity.kind == .Constant && info.mode == .Builtin {
			binding := entity_get(resolver.scopes, id)
			binding.kind = .Builtin
			binding.data = entity_get(resolver.scopes, info.entity).data
			return true, nil
		}
		if entity.kind == .Constant && info.mode == .Type {
			binding := entity_get(resolver.scopes, id)
			binding.kind = .Type_Name
			binding.type = info.type
			return true, nil
		}
		if entity.kind == .Constant && info.mode == .Value && info.entity != 0 && entity_get(resolver.scopes, info.entity).kind == .Procedure {
			file := checker.type_checker.files[declaration.value.file]
			if file.ast.nodes[type_unparen(file, declaration.value.node)].kind == .Proc_Lit {
				procedure := &entity_get(resolver.scopes, info.entity).data.(Procedure_Data)
				procedure.source_name = entity.name
			}
			binding := entity_get(resolver.scopes, id)
			binding.alias = info.entity
			binding.type = info.type
			return true, nil
		}
		if entity.kind == .Constant && info.mode == .Procedure_Group && info.entity != 0 && entity_get(resolver.scopes, info.entity).kind == .Procedure_Group {
			binding := entity_get(resolver.scopes, id)
			binding.alias = info.entity
			binding.type = info.type
			return true, nil
		}
		if entity.kind == .Constant && info.mode != .Constant {
			// Official file-scope `::` bindings of composite literals live in static storage, so they demote to
			// read-only globals instead of failing. Procedure-scope `::` still requires a constant.
			if !expression_demotable_global(checker, resolver, entity.scope, declaration.value.file, declaration.value.node, info) {
				expression_failure(checker, view, entity.scope, declaration.value.node, .Invalid_Operand) or_return
				return false, nil
			}
			demoted := entity_get(resolver.scopes, id)
			demoted.kind = .Variable
			demoted.flags += {.Immutable}
			demoted.data = Variable_Data {
				storage     = .Global,
				initializer = declaration.value,
			}
			entity.kind = .Variable
		}
		if entity.kind == .Variable && conversion_untyped(types.get(checker.type_checker.store, info.type).kind) {
			default_type := checker.default_integer
			if info.type == types.TYPE_UNTYPED_BOOL { default_type = checker.boolean }
			if info.type != types.TYPE_UNTYPED_BOOL && info.type != types.TYPE_UNTYPED_INTEGER {
				default_type = types.default_type_of_untyped(checker.type_checker.store, info.type)
			}
			info = expression_check_default(checker, view, entity.scope, declaration.value.node, default_type) or_return
			if info.state == .Invalid { return false, nil }
		}
	} else {
		if target == 0 { return false, nil }
		info = Expression_Info {
			type  = target,
			state = .Checked,
			scope = entity.scope,
		}
	}
	binding := entity_get(resolver.scopes, id)
	binding.type = info.type
	binding.constant = info.constant if entity.kind == .Constant else 0
	info.entity = id
	if entity.kind == .Variable {
		info.mode, info.constant, info.plan = .Variable, 0, 0
		if .Immutable in binding.flags { info.mode = .Immutable_Value }
	}
	expression_store(checker, view, declaration.identifier.node, info)
	return true, nil
}

// A file-scope `::` composite literal, or an alias of a demoted global, initializes static storage.
@(private = "file")
expression_demotable_global :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	scope: Scope_Id,
	file: File_Id,
	node: syntax.Node_Index,
	info: Expression_Info,
) -> bool {
	if info.mode != .Value && info.mode != .Immutable_Value { return false }
	enclosing := scope_get(resolver.scopes, scope)
	if enclosing == nil || (enclosing.kind != .File && enclosing.kind != .Package) { return false }
	if info.mode == .Immutable_Value { return true }
	source := checker.type_checker.files[file]
	value := node
	for source.ast.nodes[value].kind == .Paren_Expr {
		value = syntax.node_payload(source.ast, value, syntax.Paren_Expr).expr
	}
	return source.ast.nodes[value].kind == .Comp_Lit
}

@(private = "file")
expression_procedure_body_declaration :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	checker := cast(^Expression_Checker)user_data
	declaration := checker.type_checker.declarations[id]
	outer_instance := checker.active_instance
	checker.active_instance = entity_get(resolver.scopes, id).data.(Procedure_Data).instance
	defer checker.active_instance = outer_instance
	return expression_procedure_body(checker, resolver, id, declaration.type)
}
