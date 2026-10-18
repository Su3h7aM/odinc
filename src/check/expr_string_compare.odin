package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_string_kind :: proc(kind: types.Kind) -> bool {
	return kind == .String || kind == .String16 || kind == .CString || kind == .CString16 || kind == .Untyped_String
}

// A string or cstring comparison that is not constant calls the runtime procedure of its operator, as the official compiler does.
@(private = "package")
expression_runtime_comparison :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	left_node, right_node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	left_type: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	kind := types.get(store, conversion_base_type(store, left_type)).kind
	name := runtime_comparison_name(kind, operator)
	plan, supported, plan_error := runtime_comparison_plan(checker, name, Operand(Expression_Ref{view, left_node}), Operand(Expression_Ref{view, right_node}))
	if plan_error != nil { return {}, plan_error }
	if !supported { return expression_unsupported(checker, view, scope, node, "String_Comparison_Helper") }
	return Expression_Info{type = checker.boolean, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// Calls the runtime procedure called name with the two operands; supported is false when the runtime does not define it.
@(private = "package")
runtime_comparison_plan :: proc(checker: ^Expression_Checker, name: string, left, right: Operand) -> (plan: Plan_Id, supported: bool, err: Resolve_Error) {
	collection := checker.type_checker.collection
	if name == "" || collection == nil || collection.runtime_scope == 0 { return 0, false, nil }
	scopes := checker.type_checker.resolver.scopes
	entity := scope_lookup_current(scopes, collection.runtime_scope, name)
	if entity == 0 { return 0, false, nil }
	if _, resolve_error := resolve_entity(checker.type_checker.resolver, entity); resolve_error != nil { return 0, false, resolve_error }
	procedure, is_procedure := entity_get(scopes, entity).data.(Procedure_Data)
	if !is_procedure || len(procedure.parameters) != 2 { return 0, false, nil }
	descriptor := types.get(checker.type_checker.store, procedure.signature)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	arguments := make([]Call_Argument, 2, allocator) or_return
	operands := [2]Operand{left, right}
	for operand, index in operands {
		arguments[index] = Call_Argument {
			value            = operand,
			parameter        = procedure.parameters[index],
			evaluation_order = u32(index),
		}
	}
	results := make([]types.Type_Id, len(descriptor.results), allocator) or_return
	copy(results, descriptor.results)
	plan = Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Call_Plan{callee = Operand(entity), entity = entity, arguments = arguments, results = results})) or_return
	return plan, true, nil
}

@(private = "file")
runtime_comparison_name :: proc(kind: types.Kind, operator: syntax.Token_Kind) -> string {
	#partial switch operator {
	case .Cmp_Eq:
		#partial switch kind {
		case .CString:
			return "cstring_eq"
		case .CString16:
			return "cstring16_eq"
		case .String16:
			return "string16_eq"
		case:
			return "string_eq"
		}
	case .Not_Eq:
		#partial switch kind {
		case .CString:
			return "cstring_ne"
		case .CString16:
			return "cstring16_ne"
		case .String16:
			return "string16_ne"
		case:
			return "string_ne"
		}
	case .Lt:
		#partial switch kind {
		case .CString:
			return "cstring_lt"
		case .CString16:
			return "cstring16_lt"
		case .String16:
			return "string16_lt"
		case:
			return "string_lt"
		}
	case .Gt:
		#partial switch kind {
		case .CString:
			return "cstring_gt"
		case .CString16:
			return "cstring16_gt"
		case .String16:
			return "string16_gt"
		case:
			return "string_gt"
		}
	case .Lt_Eq:
		#partial switch kind {
		case .CString:
			return "cstring_le"
		case .CString16:
			return "cstring16_le"
		case .String16:
			return "string16_le"
		case:
			return "string_le"
		}
	case .Gt_Eq:
		#partial switch kind {
		case .CString:
			return "cstring_ge"
		case .CString16:
			return "cstring16_ge"
		case .String16:
			return "string16_ge"
		case:
			return "string_ge"
		}
	}
	return ""
}

// The tag of a string or cstring switch is bound to a hidden variable so that it is evaluated once.
@(private = "package")
expression_switch_tag :: proc(
	checker: ^Expression_Checker,
	scope: Scope_Id,
	tag_type: types.Type_Id,
) -> (
	entity: Entity_Id,
	name: string,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	kind := types.get(store, conversion_base_type(store, tag_type)).kind
	if !expression_string_kind(kind) { return 0, "", nil }
	created, create_error := entity_create(
		checker.type_checker.resolver.scopes,
		Entity {
			kind = .Variable,
			scope = scope,
			state = .Resolved,
			type = types.default_type_of_untyped(store, tag_type),
			data = Variable_Data{storage = .Local},
		},
	)
	if create_error != nil { return 0, "", binding_resolve_error(create_error) }
	return created, runtime_comparison_name(kind, .Cmp_Eq), nil
}
