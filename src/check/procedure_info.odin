package check

import "base:runtime"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_procedure_info_evaluator :: proc(
	type_checker: ^Type_Checker,
	file: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	parameters: []types.Type_Id,
	user_data: rawptr,
) -> (
	id: types.Procedure_Info_Id,
	err: Resolve_Error,
) {
	checker := cast(^Expression_Checker)user_data
	assert(checker != nil && checker.type_checker == type_checker)
	return expression_procedure_info_build(checker, file, scope, node, parameters)
}

@(private = "package")
expression_procedure_info_build :: proc(
	checker: ^Expression_Checker,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	parameters: []types.Type_Id,
) -> (
	id: types.Procedure_Info_Id,
	err: Resolve_Error,
) {
	view := expression_file_view(checker, file_id) or_return
	origin := Procedure_Info_Origin {
		signature = {file_id, node},
		scope     = scope,
		view      = view,
	}
	if existing, found := checker.procedure_info_index[origin]; found { return existing, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	info := Procedure_Info {
		defaults        = make([]Default_Argument, len(parameters), allocator) or_return,
		parameter_flags = make([]Entity_Flags, len(parameters), allocator) or_return,
	}
	file := checker.type_checker.files[file_id]
	params := syntax.node_payload(file.ast, node, syntax.Proc_Type).params
	index := 0
	if params != 0 {
		for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, params, syntax.Field_List).list) {
			field := syntax.node_payload(file.ast, field_node, syntax.Field)
			if checker.type_checker.instantiating && is_poly_name_field(file, field) { continue }
			flags: Entity_Flags
			if .Using in field.flags { flags += {.Using, .Parameter, .Immutable} }
			if .C_Vararg in field.flags { flags += {.C_Variadic} }
			if .Any_Int in field.flags { flags += {.Any_Integer} }
			if .No_Broadcast in field.flags { flags += {.No_Broadcast} }
			for _ in 0 ..< max(int(field.names.count), 1) {
				if field.default_value != 0 {
					info.defaults[index] = expression_default_argument(checker, view, scope, field.default_value, parameters[index]) or_return
					if info.defaults[index].kind == .Value {
						info.defaults[index] = Default_Argument {
							kind              = .Declaration,
							value             = Operand(Expression_Ref{view, field.default_value}),
							declaration_scope = scope,
							target_type       = parameters[index],
						}
					}
				}
				info.parameter_flags[index] = flags
				index += 1
			}
		}
	}
	return expression_procedure_info_intern(checker, origin, info)
}

@(require_results)
expression_procedure_info_intern :: proc(
	checker: ^Expression_Checker,
	origin: Procedure_Info_Origin,
	info: Procedure_Info,
) -> (
	id: types.Procedure_Info_Id,
	err: runtime.Allocator_Error,
) {
	assert(origin.signature.file != 0 && origin.signature.node != 0)
	if existing, found := checker.procedure_info_index[origin]; found { return existing, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	owned := new(Procedure_Info, allocator) or_return
	owned.defaults = make([]Default_Argument, len(info.defaults), allocator) or_return
	copy(owned.defaults, info.defaults)
	owned.parameter_flags = make([]Entity_Flags, len(info.parameter_flags), allocator) or_return
	copy(owned.parameter_flags, info.parameter_flags)
	id = types.issue_procedure_info_id(checker.type_checker.store)
	append(&checker.procedure_infos, Procedure_Info_Entry{id, origin, owned}) or_return
	checker.procedure_info_index[origin] = id
	return id, nil
}

@(require_results)
expression_procedure_info :: proc(checker: ^Expression_Checker, id: types.Procedure_Info_Id) -> (info: ^Procedure_Info, err: Procedure_Info_Error) {
	if id == 0 { return nil, .None }
	// Entries are appended in issue order, so the id indexes the table directly.
	if len(checker.procedure_infos) != 0 && id >= checker.procedure_infos[0].id {
		index := int(id - checker.procedure_infos[0].id)
		if index < len(checker.procedure_infos) && checker.procedure_infos[index].id == id {
			return checker.procedure_infos[index].info, .None
		}
	}
	return nil, .Invalid_Id
}
