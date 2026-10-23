package check

import "base:runtime"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_default_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	type: types.Type_Id,
) -> (
	argument: Default_Argument,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	if file.ast.nodes[node].kind == .Basic_Directive {
		switch expression_text(file, node) {
		case "#caller_location":
			return Default_Argument{kind = .Caller_Location}, nil
		case "#caller_expression":
			return Default_Argument{kind = .Caller_Expression}, nil
		}
		expression_unsupported(checker, view, scope, node, "Default_Directive") or_return
		return Default_Argument{kind = .Invalid}, nil
	}
	if file.ast.nodes[node].kind == .Call_Expr {
		call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
		if file.ast.nodes[call.expr].kind == .Basic_Directive && expression_text(file, call.expr) == "#caller_expression" {
			targets := syntax.node_list(file.ast, call.args)
			if len(targets) == 1 && file.ast.nodes[targets[0]].kind == .Ident {
				return Default_Argument{kind = .Caller_Expression, source_parameter = expression_text(file, targets[0])}, nil
			}
			expression_unsupported(checker, view, scope, node, "Caller_Expression_Arguments") or_return
			return Default_Argument{kind = .Invalid}, nil
		}
	}
	info := check_expression(checker, view, scope, node, type) or_return
	if info.state == .Invalid { return Default_Argument{kind = .Invalid}, nil }
	if info.constant != 0 { return Default_Argument{kind = .Constant, value = Operand(info.constant)}, nil }
	if conversion := expression_conversion_plan(checker, info.plan); conversion != 0 {
		retained := checker.plans[conversion].(Conversion_Plan)
		store := checker.type_checker.store
		if types.get(store, types.resolve_named(store, type)).kind == .Procedure {
			if source, is_expression := retained.source.(Expression_Ref); is_expression {
				original := check_expression(checker, source.view, scope, source.node) or_return
				if original.entity != 0 {
					entity := entity_get(checker.type_checker.resolver.scopes, original.entity)
					if (entity.kind == .Procedure || entity.kind == .Variable) && .Parameter not_in entity.flags {
						return Default_Argument{kind = .Value, value = retained.source, conversion = conversion}, nil
					}
				}
			}
		}
		expression_unsupported(checker, view, scope, node, "Default_Conversion") or_return
		return Default_Argument{kind = .Invalid}, nil
	}
	// Official handle_parameter_value: a non-constant default is a bare reference to another entity or the
	// context, or a compound literal of constants, re-evaluated at each call. Anything else must be a constant.
	if info.entity != 0 ||
	   info.mode == .Context ||
	   default_argument_is_context_reference(file, node) ||
	   default_compound_is_constant(checker, view, file, node) {
		return Default_Argument{kind = .Value, value = Operand(Expression_Ref{view, node})}, nil
	}
	// `typeid_of` never folds to a constant here, although official treats it as one. The
	// value is identical at every call, so re-evaluating it per call preserves behavior until
	// lowering materializes typeid values directly.
	if info.plan != 0 {
		if _, is_typeid := checker.plans[info.plan].(Typeid_Plan); is_typeid {
			return Default_Argument{kind = .Value, value = Operand(Expression_Ref{view, node})}, nil
		}
	}
	expression_unsupported(checker, view, scope, node, "Default_Constant") or_return
	return Default_Argument{kind = .Invalid}, nil
}

// Official check_expr makes a compound literal constant when each of its elements is one, so an empty literal always is.
@(private = "file")
default_compound_is_constant :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, node: syntax.Node_Index) -> bool {
	literal := type_unparen(file, node)
	if file.ast.nodes[literal].kind != .Comp_Lit { return false }
	for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, literal, syntax.Comp_Lit).elems) {
		value := element
		if file.ast.nodes[element].kind == .Field_Value {
			value = syntax.node_payload(file.ast, element, syntax.Field_Value).value
		}
		if !default_element_is_constant(checker, view, file, value) { return false }
	}
	return true
}

@(private = "file")
default_element_is_constant :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, node: syntax.Node_Index) -> bool {
	if expression_stored_info(checker, view, node).constant != 0 { return true }
	return default_compound_is_constant(checker, view, file, node)
}

// Official check_proc_type: a generic definition checks each default with the parameters bound
// so far. A bare use of a polymorphic parameter, or a compound or procedure literal over one,
// is rejected here; anything else follows the usual constant rule and is re-checked per instance.
@(private = "package")
expression_generic_default_validation :: proc(
	checker: ^Expression_Checker,
	id: Entity_Id,
	declaration: Collected_Declaration,
	scope: Scope_Id,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	valid = true
	file := checker.type_checker.files[declaration.type.file]
	view := expression_file_view(checker, declaration.type.file) or_return
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	if signature.params == 0 { return true, nil }
	placeholder_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block, id)
	if scope_error != nil { return false, binding_resolve_error(scope_error) }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	poly_names := make([dynamic]string, allocator) or_return
	params := syntax.node_payload(file.ast, signature.params, syntax.Field_List)
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		// Polymorphic names enter scope left to right: a default sees only earlier ones,
		// whether declared as `$T` parameters or bound by an earlier pattern.
		for name in syntax.node_list(file.ast, field.names) {
			collect_poly_names(file, name, &poly_names) or_return
		}
		collect_poly_names(file, field.type, &poly_names) or_return
		for poly_name in poly_names[:] {
			if scope_lookup_current(checker.type_checker.resolver.scopes, placeholder_scope, poly_name) != 0 { continue }
			bound, create_error := entity_create(
				checker.type_checker.resolver.scopes,
				Entity {
					name = poly_name,
					kind = .Type_Name,
					scope = placeholder_scope,
					package_id = entity_get(checker.type_checker.resolver.scopes, id).package_id,
					state = .Resolved,
					type = checker.default_integer,
				},
			)
			if create_error != nil { return false, binding_resolve_error(create_error) }
			if _, insert_error := scope_insert(checker.type_checker.resolver.scopes, placeholder_scope, bound); insert_error != nil {
				return false, binding_resolve_error(insert_error)
			}
		}
		if field.default_value == 0 { continue }
		default_node := type_unparen(file, field.default_value)
		if default_argument_is_poly_name(file, default_node, poly_names[:]) {
			expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Polymorphic_Constant") or_return
			valid = false
			continue
		}
		if file.ast.nodes[default_node].kind == .Comp_Lit &&
		   default_node_mentions_poly_param(file, syntax.node_payload(file.ast, default_node, syntax.Comp_Lit).type, poly_names[:]) {
			expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Polymorphic_Compound") or_return
			valid = false
			continue
		}
		if file.ast.nodes[default_node].kind == .Proc_Lit {
			literal := syntax.node_payload(file.ast, default_node, syntax.Proc_Lit)
			#partial switch file.ast.nodes[literal.type].kind {
			case .Proc_Type:
				if default_node_mentions_poly_param(file, literal.type, poly_names[:]) {
					expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Polymorphic_Procedure") or_return
					valid = false
				}
				// A clean literal is left for the instances: its body belongs to them.
				continue
			}
		}
		// A `typeid_of` over a polymorphic parameter never folds here, although it is
		// constant once instantiated. Official rejects it at the definition.
		if default_node_mentions_poly_param(file, default_node, poly_names[:]) && default_argument_is_typeid_of(file, default_node) {
			expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Constant") or_return
			valid = false
			continue
		}
		hint := types.Type_Id(0)
		if field.type != 0 && !default_node_mentions_poly_param(file, field.type, poly_names[:]) {
			hint = type_expression(checker.type_checker, declaration.type.file, placeholder_scope, field.type, true) or_return
			if hint == types.TYPE_POISON {
				valid = false
				continue
			}
		}
		argument := expression_default_argument(checker, view, placeholder_scope, field.default_value, hint) or_return
		if argument.kind == .Invalid { valid = false }
	}
	return valid, nil
}

// A bare polymorphic name used as a default value.
@(private = "file")
default_argument_is_poly_name :: proc(file: ^File, node: syntax.Node_Index, poly_names: []string) -> bool {
	kind := file.ast.nodes[node].kind
	if kind != .Ident && kind != .Poly_Type { return false }
	name := node
	if kind == .Poly_Type { name = syntax.node_payload(file.ast, node, syntax.Poly_Type).type }
	text := expression_text(file, name)
	for poly_name in poly_names {
		if poly_name == text { return true }
	}
	return false
}

// Whether a type expression mentions a polymorphic parameter, as an explicit `$T` or as a
// plain identifier naming one. Supplements poly_pattern_has_poly, which ignores identifiers.
// Collects the polymorphic names a signature binds, whether declared as `$T` parameters or
// bound by an earlier pattern, so a default sees only the parameters bound before it.
@(private = "file")
collect_poly_names :: proc(file: ^File, node: syntax.Node_Index, poly_names: ^[dynamic]string) -> runtime.Allocator_Error {
	target := type_unparen(file, node)
	if target == 0 { return nil }
	#partial switch file.ast.nodes[target].kind {
	case .Poly_Type:
		append(poly_names, expression_text(file, syntax.node_payload(file.ast, target, syntax.Poly_Type).type)) or_return
	case .Call_Expr:
		call := syntax.node_payload(file.ast, target, syntax.Call_Expr)
		collect_poly_names(file, call.expr, poly_names) or_return
		for argument in syntax.node_list(file.ast, call.args) {
			collect_poly_names(file, argument, poly_names) or_return
		}
	case .Pointer_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Pointer_Type).elem, poly_names) or_return
	case .Multi_Pointer_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Multi_Pointer_Type).elem, poly_names) or_return
	case .Dynamic_Array_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Dynamic_Array_Type).elem, poly_names) or_return
	case .Array_Type:
		array := syntax.node_payload(file.ast, target, syntax.Array_Type)
		collect_poly_names(file, array.elem, poly_names) or_return
		collect_poly_names(file, array.len, poly_names) or_return
	case .Paren_Expr:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Paren_Expr).expr, poly_names) or_return
	case .Selector_Expr:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Selector_Expr).expr, poly_names) or_return
	case .Map_Type:
		map_type := syntax.node_payload(file.ast, target, syntax.Map_Type)
		collect_poly_names(file, map_type.key, poly_names) or_return
		collect_poly_names(file, map_type.value, poly_names) or_return
	case .Field_Value:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Field_Value).value, poly_names) or_return
	case .Ellipsis:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Ellipsis).expr, poly_names) or_return
	case .Typeid_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Typeid_Type).specialization, poly_names) or_return
	}
	return nil
}

@(private = "file")
default_node_mentions_poly_param :: proc(file: ^File, node: syntax.Node_Index, poly_names: []string) -> bool {
	unparen := type_unparen(file, node)
	if unparen == 0 { return false }
	if poly_pattern_has_poly(file, unparen) { return true }
	#partial switch file.ast.nodes[unparen].kind {
	case .Ident:
		text := expression_text(file, unparen)
		for poly_name in poly_names {
			if poly_name == text { return true }
		}
	case .Paren_Expr:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Paren_Expr).expr, poly_names)
	case .Selector_Expr:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Selector_Expr).expr, poly_names)
	case .Call_Expr:
		call := syntax.node_payload(file.ast, unparen, syntax.Call_Expr)
		if default_node_mentions_poly_param(file, call.expr, poly_names) { return true }
		for argument in syntax.node_list(file.ast, call.args) {
			if default_node_mentions_poly_param(file, argument, poly_names) { return true }
		}
	case .Pointer_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Pointer_Type).elem, poly_names)
	case .Multi_Pointer_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Multi_Pointer_Type).elem, poly_names)
	case .Dynamic_Array_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Dynamic_Array_Type).elem, poly_names)
	case .Array_Type:
		array := syntax.node_payload(file.ast, unparen, syntax.Array_Type)
		return default_node_mentions_poly_param(file, array.elem, poly_names) || default_node_mentions_poly_param(file, array.len, poly_names)
	case .Ellipsis:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Ellipsis).expr, poly_names)
	case .Map_Type:
		map_type := syntax.node_payload(file.ast, unparen, syntax.Map_Type)
		return default_node_mentions_poly_param(file, map_type.key, poly_names) || default_node_mentions_poly_param(file, map_type.value, poly_names)
	case .Typeid_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Typeid_Type).specialization, poly_names)
	case .Proc_Type:
		signature := syntax.node_payload(file.ast, unparen, syntax.Proc_Type)
		for list_node in ([2]syntax.Node_Index{signature.params, signature.results}) {
			if list_node == 0 { continue }
			for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, list_node, syntax.Field_List).list) {
				field := syntax.node_payload(file.ast, field_node, syntax.Field)
				for name in syntax.node_list(file.ast, field.names) {
					if default_node_mentions_poly_param(file, name, poly_names) { return true }
				}
				if default_node_mentions_poly_param(file, field.type, poly_names) || default_node_mentions_poly_param(file, field.default_value, poly_names) {
					return true
				}
			}
		}
	}
	return false
}

// A selector chain rooted at `context`, as `context.allocator` is. The selector itself
// checks as a variable with no entity, so the root is found syntactically.
@(private = "file")
default_argument_is_typeid_of :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	current := type_unparen(file, node)
	if current == 0 || file.ast.nodes[current].kind != .Call_Expr { return false }
	callee := type_unparen(file, syntax.node_payload(file.ast, current, syntax.Call_Expr).expr)
	return callee != 0 && file.ast.nodes[callee].kind == .Ident && expression_text(file, callee) == "typeid_of"
}

@(private = "file")
default_argument_is_context_reference :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	current := node
	for {
		#partial switch file.ast.nodes[current].kind {
		case .Implicit:
			return syntax.node_payload(file.ast, current, syntax.Implicit).kind == .Context
		case .Selector_Expr:
			current = syntax.node_payload(file.ast, current, syntax.Selector_Expr).expr
		case .Paren_Expr:
			current = syntax.node_payload(file.ast, current, syntax.Paren_Expr).expr
		case:
			return false
		}
	}
}
