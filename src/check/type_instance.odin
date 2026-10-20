package check

import "core:fmt"
import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

Record_Argument_Evaluator :: #type proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	node: syntax.Node_Index,
	expected: types.Type_Id,
	user_data: rawptr,
) -> (
	type: types.Type_Id,
	constant: Const_Id,
	text: string,
	valid: bool,
	err: Resolve_Error,
)

Record_Instance :: struct {
	definition: Entity_Id,
	arguments:  []types.Type_Id,
	constants:  []Const_Id,
	type:       types.Type_Id,
}

@(private = "package")
poly_match_record :: proc(match: ^Poly_Match, pattern: syntax.Node_Index, argument: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	checker := match.checker.type_checker
	file := checker.files[match.definition_file]
	definition := record_call_definition(checker, match.definition_file, file, match.scope, pattern) or_return
	if definition == 0 { return false, nil }
	for instance in checker.record_instances {
		if instance.type != argument || instance.definition != definition { continue }
		call := syntax.node_payload(file.ast, pattern, syntax.Call_Expr)
		arguments := syntax.node_list(file.ast, call.args)
		if len(arguments) != len(instance.arguments) { return false, nil }
		for parameter, index in arguments {
			if instance.constants[index] == 0 {
				if !(poly_match_pattern(match, parameter, instance.arguments[index]) or_return) { return false, nil }
			} else if file.ast.nodes[parameter].kind == .Poly_Type {
				name := type_node_text(file, syntax.node_payload(file.ast, parameter, syntax.Poly_Type).type)
				if !(poly_bind(match.bindings, name, instance.arguments[index], instance.constants[index]) or_return) { return false, nil }
			} else {
				_, constant, _, valid := checker.evaluate_record_argument(
					checker,
					match.scope,
					match.definition_file,
					parameter,
					instance.arguments[index],
					checker.user_data,
				) or_return
				if !valid || constant != instance.constants[index] { return false, nil }
			}
		}
		return true, nil
	}
	return false, nil
}

@(private = "package")
record_poly_params :: proc(file: ^File, node: syntax.Node_Index) -> syntax.Node_Index {
	#partial switch file.ast.nodes[node].kind {
	case .Struct_Type:
		return syntax.node_payload(file.ast, node, syntax.Struct_Type).poly_params
	case .Union_Type:
		return syntax.node_payload(file.ast, node, syntax.Union_Type).poly_params
	}
	return 0
}

@(private = "package")
record_call_definition :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	definition: Entity_Id,
	err: Resolve_Error,
) {
	call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
	kind := file.ast.nodes[call.expr].kind
	if kind != .Ident && kind != .Selector_Expr { return 0, nil }
	definition = type_name_entity(checker, file, scope, call.expr)
	if definition == 0 { return 0, nil }
	entity := entity_get(checker.resolver.scopes, definition)
	if entity.kind != .Type_Name && entity.kind != .Constant { return 0, nil }
	state := resolve_type_dependency(checker, definition, type_node_span(file_id, file, node), .Name) or_return
	if state == .Invalid { return 0, nil }
	_, found := checker.generic_records[definition]
	if !found { return 0, nil }
	return definition, nil
}

@(private = "package")
record_type_call :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	definition := record_call_definition(checker, file_id, file, scope, node) or_return
	if definition == 0 {
		if checker.evaluate_type_expression != nil {
			type = checker.evaluate_type_expression(checker, scope, file_id, node, checker.user_data) or_return
			if type != 0 { return type, nil }
		}
		type_report(checker, file_id, file, node, .Not_A_Type) or_return
		return types.TYPE_POISON, nil
	}
	declaration := checker.generic_records[definition]
	definition_file := checker.files[declaration.file]
	definition_entity := entity_get(checker.resolver.scopes, definition)^
	params := syntax.node_payload(definition_file.ast, record_poly_params(definition_file, declaration.node), syntax.Field_List)
	allocator := checker.arena_allocator
	names := declared_parameter_names(definition_file, params, allocator) or_return
	arguments := syntax.node_list(file.ast, syntax.node_payload(file.ast, node, syntax.Call_Expr).args)
	slots := make([]Call_Slot, len(names), allocator) or_return
	if len(arguments) > len(names) || call_bind_arguments(file, arguments, names, len(names), slots) != "" {
		type_report(checker, file_id, file, node, .Invalid_Record_Arguments) or_return
		return types.TYPE_POISON, nil
	}
	instance_scope, scope_error := scope_create(checker.resolver.scopes, definition_entity.scope, .Block, definition)
	if scope_error != nil { return types.TYPE_POISON, binding_resolve_error(scope_error) }
	bindings := Poly_Bindings {
		names     = make([dynamic]string, 0, len(names), allocator) or_return,
		types     = make([dynamic]types.Type_Id, 0, len(names), allocator) or_return,
		constants = make([dynamic]Const_Id, 0, len(names), allocator) or_return,
	}
	instance_name := fmt.aprintf("%s(", definition_entity.name, allocator = allocator)
	parameter_index := 0
	for field_node in syntax.node_list(definition_file.ast, params.list) {
		field := syntax.node_payload(definition_file.ast, field_node, syntax.Field)
		is_type := definition_file.ast.nodes[field.type].kind == .Typeid_Type
		for _ in syntax.node_list(definition_file.ast, field.names) {
			name := names[parameter_index]
			argument_file, argument_scope, argument := file_id, scope, slots[parameter_index].value
			if argument == 0 {
				argument_file, argument_scope, argument = declaration.file, instance_scope, field.default_value
			}
			if argument != 0 && checker.files[argument_file].ast.nodes[argument].kind == .Poly_Type {
				argument = syntax.node_payload(checker.files[argument_file].ast, argument, syntax.Poly_Type).type
			}
			if argument == 0 {
				type_report(checker, file_id, file, node, .Invalid_Record_Arguments) or_return
				return types.TYPE_POISON, nil
			}
			expected := types.TYPE_NONE
			if !is_type {
				expected = type_expression(checker, declaration.file, instance_scope, field.type, true) or_return
				if expected == types.TYPE_POISON { return expected, nil }
			}
			argument_type: types.Type_Id
			constant: Const_Id
			text: string
			if is_type {
				argument_type = type_expression(checker, argument_file, argument_scope, argument, true) or_return
				if argument_type == types.TYPE_POISON { return argument_type, nil }
				text = record_type_name(checker.store, argument_type, allocator)
			} else {
				if checker.evaluate_record_argument == nil {
					type_report(checker, file_id, file, node, .Missing_Evaluator) or_return
					return types.TYPE_POISON, nil
				}
				valid: bool
				argument_type, constant, text, valid, err = checker.evaluate_record_argument(
					checker,
					argument_scope,
					argument_file,
					argument,
					expected,
					checker.user_data,
				)
				if err != nil || !valid { return types.TYPE_POISON, err }
			}
			bound := poly_bind(&bindings, name, argument_type, constant) or_return
			if !bound { return types.TYPE_POISON, nil }
			binding := Entity {
				name       = name,
				kind       = .Type_Name,
				scope      = instance_scope,
				package_id = definition_entity.package_id,
				state      = .Resolved,
				type       = argument_type,
				constant   = constant,
			}
			if !is_type { binding.kind = .Constant }
			entity, create_error := entity_create(checker.resolver.scopes, binding)
			if create_error != nil { return types.TYPE_POISON, binding_resolve_error(create_error) }
			_, insert_error := scope_insert(checker.resolver.scopes, instance_scope, entity)
			if insert_error != nil { return types.TYPE_POISON, binding_resolve_error(insert_error) }
			if parameter_index > 0 { instance_name = fmt.aprintf("%s, ", instance_name, allocator = allocator) }
			instance_name = fmt.aprintf("%s$%s=%s", instance_name, name, text, allocator = allocator)
			parameter_index += 1
		}
	}
	instance_name = fmt.aprintf("%s)", instance_name, allocator = allocator)
	for instance in checker.record_instances {
		if instance.definition != definition || len(instance.arguments) != len(bindings.types) { continue }
		same := true
		for argument, index in bindings.types {
			if argument != instance.arguments[index] || bindings.constants[index] != instance.constants[index] { same = false; break }
		}
		if same { return instance.type, nil }
	}
	kind := types.Kind.Struct
	if definition_file.ast.nodes[declaration.node].kind == .Union_Type { kind = .Union }
	instance_entity, create_error := entity_create(
		checker.resolver.scopes,
		Entity {
			name = instance_name,
			kind = .Type_Name,
			scope = instance_scope,
			package_id = definition_entity.package_id,
			declaration = definition_entity.declaration,
			state = .Resolved,
		},
	)
	if create_error != nil { return types.TYPE_POISON, binding_resolve_error(create_error) }
	type = publish_nominal(checker, instance_entity, kind, instance_name) or_return
	instance_index := len(checker.record_instances)
	append(&checker.record_instances, Record_Instance{definition, bindings.types[:], bindings.constants[:], type}) or_return
	outer_instance := checker.record_instance
	checker.record_instance = Instance_Id(instance_entity)
	defer checker.record_instance = outer_instance
	where_clauses: syntax.Node_Range
	if kind == .Struct {
		where_clauses = syntax.node_payload(definition_file.ast, declaration.node, syntax.Struct_Type).where_clauses
	} else {
		where_clauses = syntax.node_payload(definition_file.ast, declaration.node, syntax.Union_Type).where_clauses
	}
	valid := true
	for condition in syntax.node_list(definition_file.ast, where_clauses) {
		if checker.evaluate_boolean == nil {
			type_report(checker, declaration.file, definition_file, condition, .Missing_Evaluator) or_return
			valid = false
			break
		}
		value, evaluated := checker.evaluate_boolean(checker, instance_scope, declaration.file, condition, checker.user_data) or_return
		if !evaluated || !value {
			if evaluated { type_report(checker, declaration.file, definition_file, condition, .Unsatisfied_Where_Clause) or_return }
			valid = false
			break
		}
	}
	if valid {
		descriptor: types.Type
		if kind == .Struct {
			flags: []syntax.Field_Flags
			descriptor, flags, valid, err = struct_descriptor(checker, declaration.file, definition_file, instance_scope, declaration.node, instance_name)
			if err != nil { return types.TYPE_POISON, err }
			register_field_flags(checker, type, flags) or_return
		} else {
			descriptor, valid, err = union_descriptor(checker, declaration.file, definition_file, instance_scope, declaration.node, instance_name)
			if err != nil { return types.TYPE_POISON, err }
		}
		types.complete_nominal(checker.store, type, descriptor)
	}
	if !valid {
		checker.record_instances[instance_index].type = types.TYPE_POISON
		entity_get(checker.resolver.scopes, instance_entity).type = types.TYPE_POISON
		entity_get(checker.resolver.scopes, instance_entity).state = .Invalid
		return types.TYPE_POISON, nil
	}
	return type, nil
}

@(private = "package")
record_type_name :: proc(store: ^types.Store, type: types.Type_Id, allocator: mem.Allocator) -> string {
	descriptor := types.get(store, type)^
	if descriptor.name != "" { return descriptor.name }
	#partial switch descriptor.kind {
	case .Bool:
		return "bool"
	case .Integer:
		return fmt.aprintf("%s%d", "i" if descriptor.signed else "u", descriptor.count * 8, allocator = allocator)
	case .Float:
		return fmt.aprintf("f%d", descriptor.count * 8, allocator = allocator)
	case .String:
		return "string"
	case .CString:
		return "cstring"
	case .Raw_Pointer:
		return "rawptr"
	case .Type_Id:
		return "typeid"
	case .Any:
		return "any"
	case .Pointer:
		return fmt.aprintf("^%s", record_type_name(store, descriptor.elem, allocator), allocator = allocator)
	case .Multi_Pointer:
		return fmt.aprintf("[^]%s", record_type_name(store, descriptor.elem, allocator), allocator = allocator)
	case .Slice:
		return fmt.aprintf("[]%s", record_type_name(store, descriptor.elem, allocator), allocator = allocator)
	case .Dynamic_Array:
		return fmt.aprintf("[dynamic]%s", record_type_name(store, descriptor.elem, allocator), allocator = allocator)
	case .Array:
		return fmt.aprintf("[%d]%s", descriptor.count, record_type_name(store, descriptor.elem, allocator), allocator = allocator)
	case .Map:
		return fmt.aprintf(
			"map[%s]%s",
			record_type_name(store, descriptor.index, allocator),
			record_type_name(store, descriptor.elem, allocator),
			allocator = allocator,
		)
	}
	return fmt.aprintf("%v", descriptor.kind, allocator = allocator)
}

@(private = "package")
expression_record_argument_evaluator :: proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	node: syntax.Node_Index,
	expected: types.Type_Id,
	user_data: rawptr,
) -> (
	type: types.Type_Id,
	constant: Const_Id,
	text: string,
	valid: bool,
	err: Resolve_Error,
) {
	expressions := cast(^Expression_Checker)user_data
	view := expression_file_view(expressions, file) or_return
	info := check_expression(expressions, view, scope, node, expected) or_return
	if info.state == .Invalid { return types.TYPE_POISON, 0, "", false, nil }
	if info.mode != .Constant {
		type_report(checker, file, checker.files[file], node, .Invalid_Record_Arguments) or_return
		return types.TYPE_POISON, 0, "", false, nil
	}
	converted := expression_conversion(expressions, view, scope, node, Operand(info.constant), info, expected, .Assignment) or_return
	if converted.state == .Invalid { return types.TYPE_POISON, 0, "", false, nil }
	value := constant_pool_get(expressions.constants, converted.constant)
	#partial switch data in value.value {
	case big.Int:
		conversion_error: big.Error
		integer := data
		text, conversion_error = big.int_to_string(&integer, 10, allocator = checker.arena_allocator)
		if conversion_error != nil { return types.TYPE_POISON, 0, "", false, expression_constant_failure(expressions, file, node, conversion_error) }
	case bool:
		text = "true" if data else "false"
	case string:
		text = fmt.aprintf("%q", data, allocator = checker.arena_allocator)
	case:
		text = fmt.aprintf("%v", data, allocator = checker.arena_allocator)
	}
	return converted.type, converted.constant, text, true, nil
}
