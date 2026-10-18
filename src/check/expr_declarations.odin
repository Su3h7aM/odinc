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
	info := check_expression(checker, view, scope, node) or_return
	if info.state == .Invalid { return }
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
	handled, type_valid := type_declaration(checker.type_checker, id) or_return
	if handled { return type_valid, nil }
	declaration, found := checker.type_checker.declarations[id]
	if !found { return false, nil }
	entity := entity_get(resolver.scopes, id)^
	view := expression_file_view(checker, declaration.identifier.file) or_return
	if entity.kind == .Procedure && expression_in_intrinsics(checker, entity.package_id) && entity.data.(Procedure_Data).body.node == 0 {
		return expression_intrinsic_declaration(checker, resolver, id, view, declaration.identifier.node)
	}
	if entity.kind == .Import_Name { return true, nil }
	if entity.kind == .Procedure { return expression_procedure_declaration(checker, resolver, id, declaration, entity.scope) }
	if entity.kind != .Constant && entity.kind != .Variable {
		expression_unsupported(checker, view, entity.scope, declaration.identifier.node, "Declaration_Kind") or_return
		return false, nil
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
		if entity.kind == .Constant && info.mode != .Constant {
			expression_failure(checker, view, entity.scope, declaration.value.node, .Invalid_Operand) or_return
			return false, nil
		}
		if entity.kind == .Variable && conversion_untyped(types.get(checker.type_checker.store, info.type).kind) {
			default_type := checker.default_integer
			if info.type == types.TYPE_UNTYPED_BOOL { default_type = checker.boolean }
			if info.type == types.TYPE_UNTYPED_FLOAT { default_type = types.default_type_of_untyped(checker.type_checker.store, info.type) }
			info = check_expression(checker, view, entity.scope, declaration.value.node, default_type) or_return
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
	if entity.kind == .Variable { info.mode, info.constant, info.plan = .Variable, 0, 0 }
	expression_store(checker, view, declaration.identifier.node, info)
	return true, nil
}
