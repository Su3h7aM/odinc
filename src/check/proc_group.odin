package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Resolves each member of `name :: proc{...}`. Members are concrete or type-parameter generic procedures.
@(private = "package")
expression_procedure_group_declaration :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	id: Entity_Id,
	declaration: Collected_Declaration,
	scope: Scope_Id,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	view := expression_file_view(checker, declaration.value.file) or_return
	file := checker.type_checker.files[declaration.value.file]
	group := syntax.node_payload(file.ast, declaration.value.node, syntax.Proc_Group)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	members := make([dynamic]Entity_Id, 0, len(syntax.node_list(file.ast, group.args)), allocator) or_return
	for argument in syntax.node_list(file.ast, group.args) {
		member_node := argument
		if file.ast.nodes[argument].kind == .Binary_Expr {
			conditional := syntax.node_payload(file.ast, argument, syntax.Binary_Expr)
			if conditional.op.kind != .Where { continue }
			condition, ok := checker.type_checker.evaluate_boolean(
				checker.type_checker,
				scope,
				declaration.value.file,
				conditional.right,
				checker.type_checker.user_data,
			) or_return
			if !ok { return false, nil }
			if !condition { continue }
			member_node = conditional.left
		}
		member := check_expression(checker, view, scope, member_node) or_return
		if member.state == .Invalid { return false, nil }
		if member.mode != .Value || entity_get(resolver.scopes, member.entity).kind != .Procedure {
			expression_unsupported(checker, view, scope, argument, "Proc_Group_Member") or_return
			return false, nil
		}
		if rejection := group_member_rejection(checker, member.entity); rejection != "" {
			expression_unsupported(checker, view, scope, argument, rejection) or_return
			return false, nil
		}
		for existing in members {
			if existing == member.entity {
				expression_unsupported(checker, view, scope, argument, "Proc_Group_Duplicate") or_return
				return false, nil
			}
		}
		append(&members, member.entity) or_return
	}
	binding := entity_get(resolver.scopes, id)
	binding.data = Procedure_Group_Data {
		members = members[:],
	}
	return true, nil
}

// A call argument of a procedure group. The name is set for `name = value`; the info is empty for a deferred argument.
@(private = "file")
Group_Argument :: struct {
	value: syntax.Node_Index,
	name:  string,
	info:  Expression_Info,
}

// Picks the member with the highest total argument score. A tie between distinct members is ambiguous.
@(private = "package")
expression_group_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	positional := make([dynamic]Group_Argument, 0, len(arguments), allocator) or_return
	named := make([dynamic]Group_Argument, 0, len(arguments), allocator) or_return
	hinted := false
	for argument in arguments {
		group_argument := Group_Argument {
			value = argument,
		}
		if file.ast.nodes[argument].kind == .Field_Value {
			field := syntax.node_payload(file.ast, argument, syntax.Field_Value)
			if file.ast.nodes[field.field].kind != .Ident { return expression_unsupported(checker, view, scope, node, "Call_Named_Field") }
			group_argument = Group_Argument {
				value = field.value,
				name  = expression_text(file, field.field),
			}
		}
		#partial switch file.ast.nodes[group_argument.value].kind {
		case .Ternary_When_Expr, .Ternary_If_Expr:
			return expression_unsupported(checker, view, scope, node, "Group_Argument_Hint")
		}
		if group_argument_is_deferred(file, group_argument.value) {
			hinted = true
		} else {
			group_argument.info = check_expression(checker, view, scope, group_argument.value) or_return
			if group_argument.info.state == .Invalid { return expression_poison(scope), nil }
		}
		if file.ast.nodes[argument].kind == .Field_Value {
			append(&named, group_argument) or_return
		} else {
			append(&positional, group_argument) or_return
		}
	}
	members := entity_get(checker.type_checker.resolver.scopes, callee.entity).data.(Procedure_Group_Data).members
	if spread || len(named) > 0 {
		for member in members {
			if !is_generic_procedure(checker, member) { continue }
			if spread { return expression_unsupported(checker, view, scope, node, "Generic_Call_Spread") }
			return expression_unsupported(checker, view, scope, node, "Group_Named_Argument")
		}
	}
	if hinted {
		for member in members {
			if is_generic_procedure(checker, member) { return expression_unsupported(checker, view, scope, node, "Group_Argument_Hint") }
		}
	}
	best: Entity_Id
	best_score: int
	found := false
	ambiguous := false
	for member in members {
		score, matches := group_member_score(checker, view, scope, node, positional[:], named[:], spread, member) or_return
		if !matches { continue }
		if !found || score > best_score {
			best, best_score, found, ambiguous = member, score, true, false
		} else if score == best_score {
			ambiguous = true
		}
	}
	if !found { return expression_failure(checker, view, scope, node, .No_Matching_Overload) }
	if ambiguous { return expression_failure(checker, view, scope, node, .Ambiguous_Call) }
	chosen := Expression_Info {
		scope  = scope,
		state  = .Checked,
		mode   = .Value,
		entity = best,
	}
	if is_generic_procedure(checker, best) {
		return expression_generic_call(checker, view, file_id, scope, node, chosen, arguments, spread)
	}
	return expression_call(checker, view, file_id, scope, node, chosen, arguments, spread)
}

// Empty when the member can be a group entry. Otherwise the reason it is unsupported for now.
@(private = "file")
group_member_rejection :: proc(checker: ^Expression_Checker, member: Entity_Id) -> string {
	scopes := checker.type_checker.resolver.scopes
	procedure := entity_get(scopes, member).data.(Procedure_Data)
	if !procedure.generic {
		return ""
	}
	declaration := checker.type_checker.declarations[member]
	if declaration.type.node == 0 { return "Proc_Group_Polymorphic" }
	file := checker.type_checker.files[declaration.type.file]
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	params := syntax.node_payload(file.ast, signature.params, syntax.Field_List)
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		if is_poly_name_field(file, field) && !is_type_param_field(file, field) { return "Proc_Group_Polymorphic" }
	}
	return ""
}

@(private = "file")
group_member_score :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	positional: []Group_Argument,
	named: []Group_Argument,
	spread: bool,
	member: Entity_Id,
) -> (
	score: int,
	matches: bool,
	err: Resolve_Error,
) {
	if is_generic_procedure(checker, member) {
		return group_generic_member_score(checker, view, node, positional, member)
	}
	procedure := entity_get(checker.type_checker.resolver.scopes, member).data.(Procedure_Data)
	descriptor := types.get(checker.type_checker.store, procedure.signature)
	parameter_count := len(descriptor.params)
	variadic_index := procedure.variadic_index
	fixed_count := parameter_count
	if descriptor.variadic { fixed_count = variadic_index }
	if len(procedure.parameters) != parameter_count { return 0, false, nil }
	if !descriptor.variadic && len(positional) > parameter_count { return 0, false, nil }
	if spread && (!descriptor.variadic || len(positional) != variadic_index + 1) { return 0, false, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	names := make([]string, parameter_count, allocator) or_return
	for parameter, index in procedure.parameters {
		names[index] = entity_get(checker.type_checker.resolver.scopes, parameter).name
	}
	filled := make([]bool, parameter_count, allocator) or_return
	for index in 0 ..< min(len(positional), fixed_count) { filled[index] = true }
	if descriptor.variadic && len(positional) > fixed_count { filled[variadic_index] = true }
	file := checker.type_checker.files[checker.views[view].file]
	for argument in named {
		parameter := call_parameter_index(names, argument.name)
		if parameter < 0 || filled[parameter] { return 0, false, nil }
		filled[parameter] = true
		argument_score, matched := group_argument_match(checker, view, scope, file, argument.value, argument.info, descriptor.params[parameter]) or_return
		if !matched { return 0, false, nil }
		score += argument_score
	}
	for index in 0 ..< fixed_count {
		if filled[index] { continue }
		if index >= len(procedure.defaults) { return 0, false, nil }
		default_argument := procedure.defaults[index]
		if default_argument.value == nil && !default_argument.caller_location && !default_argument.caller_expression { return 0, false, nil }
	}
	if descriptor.variadic && !spread { score -= 1 }
	for argument, index in positional {
		if index >= fixed_count && !spread {
			element := types.get(checker.type_checker.store, descriptor.params[variadic_index]).elem
			argument_score, matched := group_argument_match(checker, view, scope, file, argument.value, argument.info, element) or_return
			if !matched { return 0, false, nil }
			score += argument_score - 1
			continue
		}
		argument_score, matched := group_argument_match(checker, view, scope, file, argument.value, argument.info, descriptor.params[index]) or_return
		if !matched { return 0, false, nil }
		score += argument_score
	}
	return score, true, nil
}

// Binds the member's type parameters from the argument types, as expression_generic_call does, without committing.
@(private = "file")
group_generic_member_score :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	node: syntax.Node_Index,
	positional: []Group_Argument,
	member: Entity_Id,
) -> (
	score: int,
	matches: bool,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	declaration := checker.type_checker.declarations[member]
	file := checker.type_checker.files[declaration.type.file]
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	params := syntax.node_payload(file.ast, signature.params, syntax.Field_List)
	definition_scope := entity_get(checker.type_checker.resolver.scopes, member).scope
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	bindings: Poly_Bindings
	bindings.names.allocator = allocator
	bindings.types.allocator = allocator
	bindings.constants.allocator = allocator
	match := Poly_Match {
		checker         = checker,
		call_file       = checker.views[view].file,
		call_node       = node,
		definition_file = declaration.type.file,
		scope           = definition_scope,
		bindings        = &bindings,
	}
	index := 0
	specialized := false
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		specialized = specialized || group_field_specialized(file, field)
		if field.type != 0 && file.ast.nodes[field.type].kind == .Ellipsis {
			variadic := syntax.node_payload(file.ast, field.type, syntax.Ellipsis)
			pattern := variadic.expr
			first_variadic_argument := index
			for index < len(positional) {
				info := positional[index].info
				if poly_pattern_has_poly(file, pattern) {
					matched := poly_match_pattern(&match, pattern, types.default_type_of_untyped(store, info.type)) or_return
					if !matched { return 0, false, nil }
				} else {
					bound_scope := group_bound_scope(checker, member, &bindings) or_return
					expected := type_expression(checker.type_checker, declaration.type.file, bound_scope, pattern, true) or_return
					if expected == types.TYPE_POISON { return 0, false, nil }
					argument_score, matched := group_argument_score(checker, view, positional[index].value, info, expected) or_return
					if !matched { return 0, false, nil }
					score += argument_score
				}
				index += 1
				score -= 1
			}
			if index == first_variadic_argument && poly_pattern_has_poly(file, pattern) { return 0, false, nil }
			continue
		}
		for name in syntax.node_list(file.ast, field.names) {
			if index >= len(positional) {
				if field.default_value == 0 || file.ast.nodes[name].kind == .Poly_Type { return 0, false, nil }
				continue
			}
			argument := positional[index].value
			info := positional[index].info
			index += 1
			if file.ast.nodes[name].kind == .Poly_Type {
				if info.mode != .Type { return 0, false, nil }
				poly := syntax.node_payload(file.ast, name, syntax.Poly_Type)
				bound := poly_bind(&bindings, expression_text(file, poly.type), info.type, 0) or_return
				if !bound { return 0, false, nil }
				if file.ast.nodes[field.type].kind == .Typeid_Type {
					specialization := syntax.node_payload(file.ast, field.type, syntax.Typeid_Type).specialization
					if specialization != 0 {
						matched := poly_match_pattern(&match, specialization, info.type) or_return
						if !matched { return 0, false, nil }
					}
				}
				score += 2
				continue
			}
			if field.type == 0 {
				score -= 1
				continue
			}
			if !poly_pattern_has_poly(file, field.type) {
				bound_scope := group_bound_scope(checker, member, &bindings) or_return
				expected := type_expression(checker.type_checker, declaration.type.file, bound_scope, field.type, true) or_return
				if expected == types.TYPE_POISON { return 0, false, nil }
				argument_score, matched := group_argument_score(checker, view, argument, info, expected) or_return
				if !matched { return 0, false, nil }
				score += argument_score
				continue
			}
			matched := poly_match_pattern(&match, field.type, types.default_type_of_untyped(store, info.type)) or_return
			if !matched { return 0, false, nil }
			if conversion_untyped(types.get(store, info.type).kind) {
				score += 1
			} else {
				score += 2
			}
		}
	}
	if index != len(positional) { return 0, false, nil }
	// Official order: concrete > specialized generic > unconstrained generic (check_expr.cpp:8298-8319).
	if specialized {
		score -= 1
	} else {
		score -= 2
	}
	return score, true, nil
}

@(private = "file")
group_field_specialized :: proc(file: ^File, field: syntax.Field) -> bool {
	if field.type == 0 { return false }
	#partial switch file.ast.nodes[field.type].kind {
	case .Poly_Type:
		return syntax.node_payload(file.ast, field.type, syntax.Poly_Type).specialization != 0
	case .Typeid_Type:
		return syntax.node_payload(file.ast, field.type, syntax.Typeid_Type).specialization != 0
	}
	return false
}

// An exact type scores 2, an untyped argument whose default type is the target scores 2, any other implicit
// conversion scores 1. The argument's row is not stored, so a rejected candidate leaves no trace.
@(private = "file")
group_argument_is_deferred :: proc(file: ^File, argument: syntax.Node_Index) -> bool {
	#partial switch file.ast.nodes[argument].kind {
	case .Implicit_Selector_Expr:
		return true
	case .Comp_Lit:
		return syntax.node_payload(file.ast, argument, syntax.Comp_Lit).type == 0
	}
	return false
}

// A deferred argument is checked against each candidate's parameter type inside a speculation, so the chosen
// candidate checks it again with its own hint.
@(private = "file")
group_argument_match :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file: ^File,
	argument: syntax.Node_Index,
	info: Expression_Info,
	target: types.Type_Id,
) -> (
	score: int,
	matches: bool,
	err: Resolve_Error,
) {
	if !group_argument_is_deferred(file, argument) { return group_argument_score(checker, view, argument, info, target) }
	mark := expression_speculation_begin(checker)
	defer expression_speculation_end(checker, mark)
	deferred := check_expression(checker, view, scope, argument, target) or_return
	if deferred.state == .Invalid { return 0, false, nil }
	return group_argument_score(checker, view, argument, deferred, target)
}


@(private = "file")
group_argument_score :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	argument: syntax.Node_Index,
	info: Expression_Info,
	target: types.Type_Id,
) -> (
	score: int,
	matches: bool,
	err: Resolve_Error,
) {
	if info.type == target { return 2, true, nil }
	_, diagnostic, failure := check_conversion(
		checker.constants,
		checker.type_checker.store,
		Operand(Expression_Ref{view, argument}),
		info,
		target,
		.Assignment,
		checker.config,
	)
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, argument, failure) or_return
		return 0, false, nil
	}
	if diagnostic != .None { return 0, false, nil }
	if conversion_untyped(types.get(checker.type_checker.store, info.type).kind) && group_default_type(checker, info.type) == target {
		return 2, true, nil
	}
	return 1, true, nil
}

@(private = "file")
group_default_type :: proc(checker: ^Expression_Checker, untyped: types.Type_Id) -> types.Type_Id {
	if untyped == types.TYPE_UNTYPED_INTEGER { return checker.default_integer }
	if untyped == types.TYPE_UNTYPED_BOOL { return checker.boolean }
	return types.default_type_of_untyped(checker.type_checker.store, untyped)
}
// Declares the names bound so far as type entities, as expression_instance declares them, so a later parameter can name them.
@(private = "file")
group_bound_scope :: proc(checker: ^Expression_Checker, member: Entity_Id, bindings: ^Poly_Bindings) -> (Scope_Id, Resolve_Error) {
	scopes := checker.type_checker.resolver.scopes
	definition := entity_get(scopes, member)
	if len(bindings.names) == 0 { return definition.scope, nil }
	definition_scope, package_id := definition.scope, definition.package_id
	scope, scope_error := scope_create(scopes, definition_scope, .Block, member)
	if scope_error != nil { return 0, binding_resolve_error(scope_error) }
	for name, index in bindings.names {
		bound := Entity {
			name       = name,
			kind       = .Type_Name,
			scope      = scope,
			package_id = package_id,
			state      = .Resolved,
			type       = bindings.types[index],
		}
		if bindings.constants[index] != 0 { bound.kind, bound.constant = .Constant, bindings.constants[index] }
		bound_id, create_error := entity_create(scopes, bound)
		if create_error != nil { return 0, binding_resolve_error(create_error) }
		_, insert_error := scope_insert(scopes, scope, bound_id)
		if insert_error != nil { return 0, binding_resolve_error(insert_error) }
	}
	return scope, nil
}
