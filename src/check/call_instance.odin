package check

import "base:runtime"
import "core:fmt"
import "core:math/big"
import "core:mem"
import "core:strings"
import "oc:syntax"
import "oc:types"

@(private = "package")
is_generic_procedure :: proc(checker: ^Expression_Checker, entity: Entity_Id) -> bool {
	procedure, is_procedure := entity_get(checker.type_checker.resolver.scopes, entity).data.(Procedure_Data)
	return is_procedure && procedure.generic
}

// An instance body has its own typed view, selected by its instance id.
@(private = "package")
expression_body_view :: proc(checker: ^Expression_Checker, procedure: Procedure_Data, file: File_Id) -> (view: View_Id, err: runtime.Allocator_Error) {
	outer_instance := checker.active_instance
	checker.active_instance = procedure.instance
	defer checker.active_instance = outer_instance
	return expression_file_view(checker, file)
}

// A generic callee has no value type, so it is named here instead of checked as a value.
@(private = "package")
expression_callee :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	callee: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	if file.ast.nodes[callee].kind == .Ident {
		entity, _ := scope_lookup(checker.type_checker.resolver.scopes, scope, expression_text(file, callee))
		if entity != 0 && is_generic_procedure(checker, entity) {
			return Expression_Info{scope = scope, mode = .Value, entity = entity, state = .Checked}, nil
		}
	}
	return check_expression(checker, view, scope, callee)
}

// Binds each `$T` parameter from its argument's type, then reuses or checks the instance for those types.
@(private = "package")
expression_generic_call :: proc(
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
	definition := callee.entity
	declaration := checker.type_checker.declarations[definition]
	definition_scope := entity_get(checker.type_checker.resolver.scopes, definition).scope
	if declaration.type.node == 0 { return expression_unsupported(checker, view, scope, node, "Generic_Call_Declaration") }
	file := checker.type_checker.files[declaration.type.file]
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	params := syntax.node_payload(file.ast, signature.params, syntax.Field_List)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	bindings: Poly_Bindings
	bindings.names.allocator = allocator
	bindings.types.allocator = allocator
	bindings.constants.allocator = allocator
	match := Poly_Match {
		checker         = checker,
		call_file       = file_id,
		call_node       = node,
		definition_file = declaration.type.file,
		scope           = definition_scope,
		bindings        = &bindings,
	}
	caller := checker.type_checker.files[file_id]
	names := declared_parameter_names(file, params, allocator) or_return
	variadic_index := procedure_variadic_index(file, declaration.type.node)
	if spread {
		spread_positional_count := call_positional_count(caller, arguments)
		if variadic_index < 0 { return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread") }
		if spread_positional_count > variadic_index + 1 { return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread_Arguments") }
		if spread_positional_count != variadic_index + 1 { return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread_Position") }
	}
	positional_count := call_positional_count(caller, arguments)
	expansions := call_expansions(checker, view, scope, caller, arguments[:positional_count]) or_return
	if expansions != nil && spread {
		return expression_unsupported(checker, view, scope, node, "Call_Tuple_Variadic_Spread")
	}
	expanded_count := len(arguments)
	for results in expansions {
		if results != nil { expanded_count += len(results) - 1 }
	}
	if variadic_index < 0 && expanded_count > len(names) {
		return expression_unsupported(checker, view, scope, node, "Call_Arguments")
	}
	fixed_count := len(names)
	if variadic_index >= 0 { fixed_count = variadic_index + 1 }
	slots := make([]Call_Slot, len(names), allocator) or_return
	if reason := call_bind_arguments(caller, arguments, names, fixed_count, slots, expansions); reason != "" {
		return expression_unsupported(checker, view, scope, node, reason)
	}
	if positional_count > fixed_count && positional_count < len(arguments) {
		return expression_unsupported(checker, view, scope, node, "Generic_Call_Named_Variadic")
	}
	is_runtime := make([]bool, len(arguments), allocator) or_return
	for index in fixed_count ..< positional_count {
		is_runtime[index] = true
	}
	parameter_index := 0
	runtime_arguments: [dynamic]syntax.Node_Index
	runtime_arguments.allocator = allocator
	deferred: [dynamic]Untyped_Pattern
	deferred.allocator = allocator
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		for name in syntax.node_list(file.ast, field.names) {
			slot := slots[parameter_index]
			parameter_index += 1
			if slot.value == 0 {
				if field.type != 0 && file.ast.nodes[field.type].kind == .Ellipsis { continue }
				if field.default_value == 0 || file.ast.nodes[name].kind == .Poly_Type {
					return expression_unsupported(checker, view, scope, node, "Generic_Call_Arguments")
				}
				continue
			}
			argument_node := slot.value
			if file.ast.nodes[name].kind == .Poly_Type && !is_type_param_field(file, field) {
				// `$N: $I` makes the constant's type a polymorphic type name, bound to the argument's type.
				constant_type_name := poly_constant_type_name(file, field.type)
				constant_type: types.Type_Id
				argument_hint: types.Type_Id
				if constant_type_name == "" {
					constant_type = type_expression(checker.type_checker, declaration.type.file, definition_scope, field.type, true) or_return
					if constant_type == types.TYPE_POISON { return expression_poison(scope), nil }
					argument_hint = constant_type
				}
				argument := generic_call_argument(checker, view, scope, slot, expansions, argument_hint) or_return
				if argument.state == .Invalid { return expression_poison(scope), nil }
				procedure_entity := Entity_Id(0)
				if argument.mode != .Constant { procedure_entity = expression_procedure_argument(checker, view, scope, slot.value) }
				procedure_argument := procedure_entity != 0
				if argument.mode != .Constant && !procedure_argument {
					return expression_unsupported(checker, view, scope, node, "Generic_Call_Constant_Parameter")
				}
				if procedure_argument {
					store := checker.type_checker.store
					if constant_type_name != "" {
						constant_type = argument.type
						bound := poly_bind(store, &bindings, constant_type_name, constant_type, 0) or_return
						if !bound { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict") }
					} else if !types.are_identical(store, argument.type, constant_type) {
						return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict")
					}
					identity: big.Int
					defer big.destroy(&identity)
					if set_error := big.set(&identity, int(procedure_entity)); set_error != nil {
						expression_constant_failure(checker, file_id, node, set_error) or_return
						return expression_poison(scope), nil
					}
					key, key_error := constant_pool_intern_integer(checker.constants, &identity, constant_type)
					if key_error != nil {
						expression_constant_failure(checker, file_id, node, key_error) or_return
						return expression_poison(scope), nil
					}
					poly_name := expression_text(file, syntax.node_payload(file.ast, name, syntax.Poly_Type).type)
					if !(poly_bind(store, &bindings, poly_name, constant_type, key) or_return) {
						return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict")
					}
					continue
				}
				if constant_type_name != "" {
					constant_type = types.default_type_of_untyped(checker.type_checker.store, argument.type)
					bound := poly_bind(checker.type_checker.store, &bindings, constant_type_name, constant_type, 0) or_return
					if !bound { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict") }
				}
				converted := expression_conversion(
					checker,
					view,
					scope,
					argument_node,
					Operand(Expression_Ref{view, argument_node}),
					argument,
					constant_type,
					.Assignment,
				) or_return
				if converted.state == .Invalid { return expression_poison(scope), nil }
				poly_name := expression_text(file, syntax.node_payload(file.ast, name, syntax.Poly_Type).type)
				bound := poly_bind(checker.type_checker.store, &bindings, poly_name, constant_type, converted.constant) or_return
				if !bound { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict") }
				continue
			}
			argument_hint: types.Type_Id
			hint_pattern := field.type
			if hint_pattern != 0 && file.ast.nodes[hint_pattern].kind == .Ellipsis && !spread {
				hint_pattern = syntax.node_payload(file.ast, hint_pattern, syntax.Ellipsis).expr
			}
			if expression_argument_needs_hint(caller, argument_node) && !poly_pattern_has_poly(file, hint_pattern) {
				if hint_pattern != 0 {
					// A pattern can mention names bound by other parameters. Resolve the
					// hint speculatively; an unresolved dependent pattern is not a hint.
					bound_hint_scope := poly_bound_scope(&match) or_return
					mark := expression_speculation_begin(checker)
					hint_type, hint_error := type_expression(checker.type_checker, declaration.type.file, bound_hint_scope, hint_pattern, true)
					expression_speculation_end(checker, mark)
					if hint_error == nil && hint_type != types.TYPE_POISON { argument_hint = hint_type }
				} else {
					// The default may name parameters bound by earlier arguments, so it is
					// inferred in the bound scope like a concrete pattern. Speculation keeps
					// rows keyed by the default node from leaking into the next call.
					bound_hint_scope := poly_bound_scope(&match) or_return
					mark := expression_speculation_begin(checker)
					default_hint, _, hint_error := default_parameter_type(
						checker.type_checker,
						declaration.type.file,
						file,
						bound_hint_scope,
						field.default_value,
					)
					expression_speculation_end(checker, mark)
					if hint_error != nil { return {}, hint_error }
					argument_hint = default_hint
				}
			}
			if argument_hint == 0 &&
			   hint_pattern != 0 &&
			   file.ast.nodes[hint_pattern].kind == .Poly_Type &&
			   expression_argument_needs_hint(caller, argument_node) {
				poly_name := expression_text(file, syntax.node_payload(file.ast, hint_pattern, syntax.Poly_Type).type)
				for bound_name, index in match.bindings.names {
					if bound_name == poly_name && match.bindings.constants[index] == 0 { argument_hint = match.bindings.types[index] }
				}
			}
			argument := generic_call_argument(checker, view, scope, slot, expansions, argument_hint) or_return
			if argument.state == .Invalid { return expression_poison(scope), nil }
			if file.ast.nodes[name].kind == .Poly_Type {
				if argument.mode !=
				   .Type { return expression_failure(checker, view, scope, argument_node, .Invalid_Operand, "Expected a type to assign to the type parameter") }
				poly := syntax.node_payload(file.ast, name, syntax.Poly_Type)
				matched := poly_bind(checker.type_checker.store, &bindings, expression_text(file, poly.type), argument.type, 0) or_return
				if matched && file.ast.nodes[field.type].kind == .Typeid_Type {
					specialization := syntax.node_payload(file.ast, field.type, syntax.Typeid_Type).specialization
					if specialization != 0 { matched = poly_match_pattern(&match, specialization, argument.type) or_return }
				}
				if !matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict") }
				continue
			}
			is_runtime[slot.position] = true
			if _, generic := expression_generic_procedure_reference(checker, view, scope, argument_node) or_return; generic {
				// A generic procedure value binds no name, so a polymorphic pattern cannot take its type, as official rejects it.
				if field.type != 0 && poly_pattern_has_poly(file, field.type) {
					return expression_failure(
						checker,
						view,
						scope,
						argument_node,
						.Invalid_Operand,
						"Cannot determine complete type of partial polymorphic procedure",
					)
				}
				// A concrete pattern is checked by the instance call against the parameter type.
				continue
			}
			if spread && file.ast.nodes[field.type].kind == .Ellipsis {
				matched := poly_match_spread(&match, field.type, argument.type) or_return
				if !matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Spread_Type") }
				continue
			}
			if poly_untyped_deferred(file, field.type, types.get(checker.type_checker.store, argument.type).kind) {
				append(&deferred, Untyped_Pattern{pattern = field.type, type = argument.type}) or_return
				continue
			}
			if field.type == 0 {
				// The default may name parameters bound by earlier arguments, so it is
				// inferred in the bound scope like a concrete pattern. Speculation keeps
				// rows keyed by the default node from leaking into the next call.
				bound_default_scope := poly_bound_scope(&match) or_return
				mark := expression_speculation_begin(checker)
				default_type, default_found, default_error := default_parameter_type(
					checker.type_checker,
					declaration.type.file,
					file,
					bound_default_scope,
					field.default_value,
				)
				expression_speculation_end(checker, mark)
				if default_error != nil { return {}, default_error }
				if default_found && default_type == types.TYPE_POISON {
					return expression_unsupported(checker, view, scope, node, "Generic_Call_Default_Type")
				}
				if default_found {
					converted := expression_conversion(
						checker,
						view,
						scope,
						argument_node,
						Operand(Expression_Ref{view, argument_node}),
						argument,
						default_type,
						.Assignment,
					) or_return
					if converted.state == .Invalid { return expression_poison(scope), nil }
				}
			}
			// A concrete pattern is resolved against the parameters bound so far, as the group scorer
			// does. A bare name bound only later, or never, rejects the call the way official does.
			if !poly_pattern_has_poly(file, field.type) {
				if field.type != 0 && file.ast.nodes[field.type].kind == .Ident && poly_name_deferred(&match, deferred[:], expression_text(file, field.type)) {
					if conversion_untyped(types.get(checker.type_checker.store, argument.type).kind) {
						append(&deferred, Untyped_Pattern{pattern = field.type, type = argument.type}) or_return
					} else {
						bound := poly_bind(checker.type_checker.store, &bindings, expression_text(file, field.type), argument.type, 0) or_return
						if !bound { return expression_unsupported(checker, view, scope, node, "Generic_Call_Pattern") }
					}
					continue
				}
				if field.type != 0 && file.ast.nodes[field.type].kind != .Ellipsis {
					poly_bind_deferred_in_pattern(&match, field.type, argument.type, deferred[:]) or_return
					bound_scope := poly_bound_scope(&match) or_return
					mark := expression_speculation_begin(checker)
					expected, type_error := type_expression(checker.type_checker, declaration.type.file, bound_scope, field.type, true)
					expression_speculation_end(checker, mark)
					if type_error != nil { return {}, type_error }
					if expected == types.TYPE_POISON {
						return expression_unsupported(checker, view, scope, node, "Generic_Call_Pattern")
					}
				}
				continue
			}
			poly_argument := types.default_type_of_untyped(checker.type_checker.store, argument.type)
			poly_bind_deferred_in_pattern(&match, field.type, poly_argument, deferred[:]) or_return
			matched := poly_match_pattern(&match, field.type, poly_argument) or_return
			if !matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Pattern") }
		}
	}
	deferred_matched := poly_bind_deferred(&match, deferred[:]) or_return
	if !deferred_matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Pattern") }
	for argument, index in arguments {
		if is_runtime[index] { append(&runtime_arguments, argument) or_return }
	}
	scopes := checker.type_checker.resolver.scopes
	key := instance_index_key(checker.type_checker.store, definition, bindings.types[:], bindings.constants[:])
	for id in instance_index_candidates(&checker.type_checker.resolver.instances, key) {
		procedure := &entity_get(scopes, id).data.(Procedure_Data)
		if procedure.definition != definition ||
		   !same_type_arguments(checker.type_checker.store, procedure.poly_arguments, bindings.types[:]) ||
		   !same_elements(procedure.poly_constants, bindings.constants[:]) { continue }
		return expression_instance_call(checker, view, file_id, scope, node, id, runtime_arguments[:], spread)
	}
	return expression_new_instance(
		checker,
		view,
		file_id,
		scope,
		node,
		definition,
		declaration,
		bindings.names[:],
		bindings.types[:],
		bindings.constants[:],
		runtime_arguments[:],
		spread,
	)
}

// An argument's value. One result of a multi-result call is typed by its result, so the call is checked once.
@(private = "package")
generic_call_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	slot: Call_Slot,
	expansions: [][]types.Type_Id,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if slot.element == 0 { return check_expression(checker, view, scope, slot.value, hint) }
	result := expansions[slot.position][slot.element - 1]
	return Expression_Info{type = result, mode = .Value, scope = scope, state = .Checked}, nil
}

// A `$T: typeid` parameter binds a type at compile time; it is not a runtime parameter.
@(private = "package")
is_type_param_field :: proc(file: ^File, field: syntax.Field) -> bool {
	if field.names.count == 0 || file.ast.nodes[field.type].kind != .Typeid_Type { return false }
	return file.ast.nodes[syntax.node_list(file.ast, field.names)[0]].kind == .Poly_Type
}

// A `$T` or `$N` name is bound by the call, so the instance signature leaves the parameter out.
@(private = "package")
is_poly_name_field :: proc(file: ^File, field: syntax.Field) -> bool {
	return field.names.count > 0 && file.ast.nodes[syntax.node_list(file.ast, field.names)[0]].kind == .Poly_Type
}

// The type name that a constant parameter's `$I` type declares, or "" when its type is concrete.
@(private = "file")
poly_constant_type_name :: proc(file: ^File, type_node: syntax.Node_Index) -> string {
	if type_node == 0 { return "" }
	node := type_unparen(file, type_node)
	if file.ast.nodes[node].kind != .Poly_Type { return "" }
	poly := syntax.node_payload(file.ast, node, syntax.Poly_Type)
	if poly.specialization != 0 { return "" }
	return expression_text(file, poly.type)
}

// A spread's slice matches the `..P` parameter's element pattern P. A bare name that the definition does not declare is one of its polymorphic names.
@(private = "package")
poly_match_spread :: proc(match: ^Poly_Match, variadic: syntax.Node_Index, slice: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	store := match.checker.type_checker.store
	file := match.checker.type_checker.files[match.definition_file]
	descriptor := types.get(store, underlying_type(store, slice))
	if descriptor.kind != .Slice { return false, nil }
	pattern := syntax.node_payload(file.ast, variadic, syntax.Ellipsis).expr
	if file.ast.nodes[pattern].kind == .Ident {
		name := expression_text(file, pattern)
		if entity, _ := scope_lookup(match.checker.type_checker.resolver.scopes, match.scope, name); entity == 0 {
			return poly_bind(match.checker.type_checker.store, match.bindings, name, descriptor.elem, 0)
		}
	}
	return poly_match_pattern(match, pattern, descriptor.elem)
}

// Untyped arguments bind bare polymorphic names only after the typed arguments.
@(private = "package")
Untyped_Pattern :: struct {
	pattern: syntax.Node_Index,
	type:    types.Type_Id,
}

@(private = "package")
poly_untyped_deferred :: proc(file: ^File, pattern: syntax.Node_Index, kind: types.Kind) -> bool {
	if file.ast.nodes[pattern].kind != .Poly_Type || !conversion_untyped(kind) { return false }
	return syntax.node_payload(file.ast, pattern, syntax.Poly_Type).specialization == 0
}

// The text of a deferred pattern's name: `$T` names T, and a bare T names T.
@(private = "package")
poly_pattern_name :: proc(file: ^File, pattern: syntax.Node_Index) -> string {
	if file.ast.nodes[pattern].kind == .Ident { return expression_text(file, pattern) }
	return expression_text(file, syntax.node_payload(file.ast, pattern, syntax.Poly_Type).type)
}

// Whether name is declared by an earlier untyped `$T` argument and not bound yet.
@(private = "file")
poly_name_deferred :: proc(match: ^Poly_Match, deferred: []Untyped_Pattern, name: string) -> bool {
	for bound_name in match.bindings.names {
		if bound_name == name { return false }
	}
	file := match.checker.type_checker.files[match.definition_file]
	for entry in deferred {
		if poly_pattern_name(file, entry.pattern) == name { return true }
	}
	return false
}

// A typed argument binds a deferred untyped name reached through a compound type, so the
// untyped argument then converts to that binding instead of fixing the name to its default type.
@(private = "file")
poly_bind_deferred_in_pattern :: proc(
	match: ^Poly_Match,
	pattern: syntax.Node_Index,
	argument: types.Type_Id,
	deferred: []Untyped_Pattern,
) -> (
	err: Resolve_Error,
) {
	store := match.checker.type_checker.store
	file := match.checker.type_checker.files[match.definition_file]
	descriptor := types.get(store, argument)
	#partial switch file.ast.nodes[pattern].kind {
	case .Poly_Type:
		poly := syntax.node_payload(file.ast, pattern, syntax.Poly_Type)
		if poly.specialization != 0 {
			return poly_bind_deferred_in_pattern(match, poly.specialization, argument, deferred)
		}
	case .Proc_Type:
		if descriptor.kind != .Procedure { return nil }
		signature := syntax.node_payload(file.ast, pattern, syntax.Proc_Type)
		for fields, index in ([2]syntax.Node_Index{signature.params, signature.results}) {
			if fields == 0 { continue }
			field_types := descriptor.params if index == 0 else descriptor.results
			position := 0
			for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, fields, syntax.Field_List).list) {
				field := syntax.node_payload(file.ast, field_node, syntax.Field)
				for _ in 0 ..< max(1, len(syntax.node_list(file.ast, field.names))) {
					if position >= len(field_types) { return nil }
					poly_bind_deferred_in_pattern(match, field.type, field_types[position], deferred) or_return
					position += 1
				}
			}
		}
	case .Ident:
		name := expression_text(file, pattern)
		if poly_name_deferred(match, deferred, name) {
			_ = poly_bind(store, match.bindings, name, argument, 0) or_return
		}
	case .Array_Type:
		if descriptor.kind != .Array { return nil }
		elem := syntax.node_payload(file.ast, pattern, syntax.Array_Type).elem
		return poly_bind_deferred_in_pattern(match, elem, descriptor.elem, deferred)
	case .Pointer_Type:
		if descriptor.kind != .Pointer { return nil }
		elem := syntax.node_payload(file.ast, pattern, syntax.Pointer_Type).elem
		return poly_bind_deferred_in_pattern(match, elem, descriptor.elem, deferred)
	}
	return nil
}

// Binds each deferred untyped argument's name to its default type, unless a typed argument bound the name first.
@(private = "package")
poly_bind_deferred :: proc(match: ^Poly_Match, deferred: []Untyped_Pattern) -> (matched: bool, err: Resolve_Error) {
	store := match.checker.type_checker.store
	file := match.checker.type_checker.files[match.definition_file]
	for entry in deferred {
		name := poly_pattern_name(file, entry.pattern)
		bound := false
		for bound_name in match.bindings.names { bound ||= bound_name == name }
		if bound { continue }
		default_type := types.default_type_of_untyped(store, entry.type)
		if file.ast.nodes[entry.pattern].kind == .Ident {
			matched = poly_bind(store, match.bindings, name, default_type, 0) or_return
		} else {
			matched = poly_match_pattern(match, entry.pattern, default_type) or_return
		}
		if !matched { return false, nil }
	}
	return true, nil
}

@(private = "package")
same_elements :: proc(left, right: []$T) -> bool {
	if len(left) != len(right) { return false }
	for type, index in left {
		if type != right[index] { return false }
	}
	return true
}

@(private = "package")
same_type_arguments :: proc(store: ^types.Store, left, right: []types.Type_Id) -> bool {
	if len(left) != len(right) { return false }
	for type, index in left {
		if !types.are_identical_unique_tuples(store, type, right[index]) { return false }
	}
	return true
}

Instance_Poly_Name :: struct {
	name:        string,
	declared_at: syntax.Node_Index,
	type:        types.Type_Id,
	constant:    Const_Id,
}

// A poly name is visible to a signature field declared at or after the field that binds it.
Instance_Poly_Names :: struct {
	owner:      Entity_Id,
	package_id: Package_Id,
	names:      []Instance_Poly_Name,
}

@(private = "package")
instance_field_scope :: proc(checker: ^Type_Checker, scope: Scope_Id, field_node: syntax.Node_Index) -> (Scope_Id, Resolve_Error) {
	poly := checker.instance_poly
	visible := false
	for name in poly.names { visible ||= name.declared_at <= field_node }
	if !visible { return scope, nil }
	scopes := checker.resolver.scopes
	field_scope, scope_error := scope_create(scopes, scope, .Block, poly.owner)
	if scope_error != nil { return 0, binding_resolve_error(scope_error) }
	for name in poly.names {
		if name.declared_at > field_node { continue }
		bound_entity := Entity {
			name       = name.name,
			kind       = .Type_Name,
			scope      = field_scope,
			package_id = poly.package_id,
			state      = .Resolved,
			type       = name.type,
		}
		if name.constant != 0 {
			bound_entity.kind, bound_entity.constant = .Constant, name.constant
		}
		bound, bound_error := entity_create(scopes, bound_entity)
		if bound_error != nil { return 0, binding_resolve_error(bound_error) }
		_, insert_error := scope_insert(scopes, field_scope, bound)
		if insert_error != nil { return 0, binding_resolve_error(insert_error) }
	}
	return field_scope, nil
}

@(private = "file")
poly_marker_in :: proc(text: string, name: string) -> bool {
	for start in 0 ..< len(text) {
		if text[start] != '$' || !strings.has_prefix(text[start + 1:], name) { continue }
		end := start + 1 + len(name)
		if end == len(text) { return true }
		c := text[end]
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') { return true }
	}
	return false
}

@(private = "file")
poly_declaration_node :: proc(file: ^File, signature: syntax.Node_Index, name: string) -> syntax.Node_Index {
	params := syntax.node_payload(file.ast, signature, syntax.Proc_Type).params
	if params == 0 { return 0 }
	for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, params, syntax.Field_List).list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		if field.type != 0 && poly_marker_in(type_node_text(file, field.type), name) { return field_node }
		for name_node in syntax.node_list(file.ast, field.names) {
			if poly_marker_in(type_node_text(file, name_node), name) { return field_node }
		}
	}
	return 0
}

@(private = "file")
expression_new_instance :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	definition: Entity_Id,
	declaration: Collected_Declaration,
	poly_names: []string,
	poly_types: []types.Type_Id,
	poly_constants: []Const_Id,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	instance, failure, created := expression_create_instance(
		checker,
		view,
		scope,
		node,
		definition,
		declaration,
		poly_names,
		poly_types,
		poly_constants,
	) or_return
	if !created { return failure, nil }
	return expression_instance_call(checker, view, file_id, scope, node, instance, arguments, spread)
}

// Checks a new instance of a generic procedure for the bound names. `failure` is the row to publish when it cannot be made.
@(private = "package")
expression_create_instance :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	definition: Entity_Id,
	declaration: Collected_Declaration,
	poly_names: []string,
	poly_types: []types.Type_Id,
	poly_constants: []Const_Id,
) -> (
	result: Entity_Id,
	failure: Expression_Info,
	created: bool,
	err: Resolve_Error,
) {
	resolver := checker.type_checker.resolver
	scopes := resolver.scopes
	definition_entity := entity_get(scopes, definition)
	definition_procedure := definition_entity.data.(Procedure_Data)
	definition_package_id := definition_entity.package_id
	definition_name := definition_entity.name
	definition_disabled := .Disabled in definition_entity.flags
	definition_declaration := definition_entity.declaration
	arena := mem.dynamic_arena_allocator(&checker.arena)
	type_scope, scope_error := scope_create(scopes, definition_entity.scope, .Block, definition)
	if scope_error != nil { return 0, {}, false, binding_resolve_error(scope_error) }
	signature_scope, signature_scope_error := scope_create(scopes, definition_entity.scope, .Block, definition)
	if signature_scope_error != nil { return 0, {}, false, binding_resolve_error(signature_scope_error) }
	file := checker.type_checker.files[declaration.type.file]
	poly_declarations := make([]Instance_Poly_Name, len(poly_names), arena) or_return
	for name, index in poly_names {
		poly_declarations[index] = Instance_Poly_Name {
			name        = name,
			declared_at = poly_declaration_node(file, declaration.type.node, name),
			type        = poly_types[index],
			constant    = poly_constants[index],
		}
	}
	for name, index in poly_names {
		if poly_constants[index] != 0 &&
		   types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, poly_types[index])).kind == .Procedure {
			identity := constant_pool_get(checker.constants, poly_constants[index]).value.(big.Int)
			procedure_id, _ := big.int_get_i64(&identity)
			_, insert_error := scope_insert_with_name(scopes, type_scope, name, Entity_Id(procedure_id))
			if insert_error != nil { return 0, {}, false, binding_resolve_error(insert_error) }
			continue
		}
		bound_entity := Entity {
			name       = name,
			kind       = .Type_Name,
			scope      = type_scope,
			package_id = definition_package_id,
			state      = .Resolved,
			type       = poly_types[index],
		}
		if poly_constants[index] != 0 {
			bound_entity.kind, bound_entity.constant = .Constant, poly_constants[index]
		}
		bound, bound_error := entity_create(scopes, bound_entity)
		if bound_error != nil { return 0, {}, false, binding_resolve_error(bound_error) }
		_, insert_error := scope_insert(scopes, type_scope, bound)
		if insert_error != nil { return 0, {}, false, binding_resolve_error(insert_error) }
	}
	name := fmt.aprintf("%s[%v|%v]", definition_name, poly_types, poly_constants, allocator = arena)
	instance, create_error := entity_create(
		scopes,
		Entity {
			name = name,
			kind = .Procedure,
			scope = type_scope,
			package_id = definition_package_id,
			declaration = definition_declaration,
			flags = {.Disabled} if definition_disabled else {},
			state = .Resolving,
			data = Procedure_Data {
				definition = definition,
				atomic = definition_procedure.atomic,
				poly_arguments = poly_types,
				poly_constants = poly_constants,
				body = definition_procedure.body if !definition_disabled else {},
				where_clauses = definition_procedure.where_clauses,
				body_state = .Unchecked,
			},
		},
	)
	if create_error != nil { return 0, {}, false, binding_resolve_error(create_error) }
	instance_key := instance_index_key(checker.type_checker.store, definition, poly_types, poly_constants)
	instance_index_insert(&resolver.instances, resolver.allocator, instance_key, instance) or_return
	procedure := &entity_get(scopes, instance).data.(Procedure_Data)
	procedure.instance = Instance_Id(instance)
	outer_instantiating := checker.type_checker.instantiating
	checker.type_checker.instantiating = true
	outer_instance := checker.active_instance
	checker.active_instance = Instance_Id(instance)
	outer_poly_names := checker.type_checker.instance_poly
	checker.type_checker.instance_poly = Instance_Poly_Names {
		owner      = definition,
		package_id = definition_package_id,
		names      = poly_declarations,
	}
	signature, signature_error := type_expression(checker.type_checker, declaration.type.file, signature_scope, declaration.type.node, true)
	checker.type_checker.instance_poly = outer_poly_names
	checker.active_instance = outer_instance
	checker.type_checker.instantiating = outer_instantiating
	if signature_error != nil { return 0, {}, false, signature_error }
	if signature == types.TYPE_POISON { return 0, expression_poison(scope), false, nil }
	descriptor := types.get(checker.type_checker.store, signature)
	entity := entity_get(scopes, instance)
	entity.type = signature
	procedure = &entity.data.(Procedure_Data)
	procedure.signature = signature
	procedure.convention = descriptor.convention
	procedure.variadic_index = procedure_variadic_index(checker.type_checker.files[declaration.type.file], declaration.type.node)
	checker.active_instance = Instance_Id(instance)
	valid: bool
	body_error: Resolve_Error
	if resolver.body_pause_depth > 0 && !definition_disabled {
		valid, body_error = expression_queue_instance_body(checker, resolver, instance, declaration)
	} else {
		valid, body_error = expression_procedure_body(checker, resolver, instance, declaration.type)
	}
	checker.active_instance = outer_instance
	if body_error != nil { return 0, {}, false, body_error }
	entity_get(scopes, instance).state = .Resolved if valid else .Invalid
	if !valid || !definition_disabled && resolver.body_pause_depth == 0 && entity_get(scopes, instance).data.(Procedure_Data).body_state != .Complete {
		if !valid && definition_procedure.where_clauses.count != 0 {
			failure, err = expression_failure(checker, view, scope, node, .Invalid_Operand, "at caller location")
			return 0, failure, false, err
		}
		return 0, expression_poison(scope), false, nil
	}
	return instance, {}, true, nil
}

@(private = "file")
expression_instance_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	instance: Entity_Id,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	entity := entity_get(checker.type_checker.resolver.scopes, instance)
	procedure := entity.data.(Procedure_Data)
	if entity.state != .Resolved {
		if entity.state == .Invalid && procedure.where_clauses.count != 0 {
			return expression_failure(checker, view, scope, node, .Invalid_Operand, "at caller location")
		}
		// A recursive call finds its own instance still resolving. The signature is assigned before the
		// body is checked, so the call checks against the known signature, like upstream's reuse of an
		// in-progress specialization. Anything else keeps today's silent poison.
		if entity.state != .Resolving || procedure.signature == types.TYPE_NONE { return expression_poison(scope), nil }
	}
	if procedure.body_state == .Invalid {
		return expression_poison(scope), nil
	}
	callee := Expression_Info {
		scope  = scope,
		mode   = .Value,
		type   = entity.type,
		entity = instance,
		state  = .Checked,
	}
	return expression_call(checker, view, file_id, scope, node, callee, arguments, spread)
}

// The non-generic procedure that an argument of a constant parameter names, which is bound by identity.
// A local procedure constant aliases the literal it was declared with.
@(private = "file")
expression_procedure_argument :: proc(checker: ^Expression_Checker, view: View_Id, scope: Scope_Id, node: syntax.Node_Index) -> Entity_Id {
	file := checker.type_checker.files[checker.views[view].file]
	target := type_unparen(file, node)
	if file.ast.nodes[target].kind == .Proc_Lit { return expression_procedure_entity(checker, expression_stored_info(checker, view, target).entity) }
	entity_id := type_name_entity(checker.type_checker, file, scope, target)
	if entity_id == 0 { return 0 }
	entity := entity_get(checker.type_checker.resolver.scopes, entity_id)
	if entity.kind == .Constant { return expression_procedure_entity(checker, entity.alias) }
	return expression_procedure_entity(checker, entity_id)
}

@(private = "file")
expression_procedure_entity :: proc(checker: ^Expression_Checker, id: Entity_Id) -> Entity_Id {
	if id == 0 { return 0 }
	entity := entity_get(checker.type_checker.resolver.scopes, id)
	procedure, is_procedure := entity.data.(Procedure_Data)
	if entity.kind != .Procedure || !is_procedure || procedure.generic { return 0 }
	return id
}
