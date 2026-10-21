package check

import "base:runtime"
import "core:mem"
import "oc:types"

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
	for entry in checker.procedure_infos {
		if entry.origin == origin { return entry.id, nil }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	owned := new(Procedure_Info, allocator) or_return
	owned.defaults = make([]Default_Argument, len(info.defaults), allocator) or_return
	copy(owned.defaults, info.defaults)
	owned.parameter_flags = make([]Entity_Flags, len(info.parameter_flags), allocator) or_return
	copy(owned.parameter_flags, info.parameter_flags)
	id = types.issue_procedure_info_id(checker.type_checker.store)
	append(&checker.procedure_infos, Procedure_Info_Entry{id, origin, owned}) or_return
	return id, nil
}

@(require_results)
expression_procedure_info :: proc(checker: ^Expression_Checker, id: types.Procedure_Info_Id) -> (info: ^Procedure_Info, err: Procedure_Info_Error) {
	if id == 0 { return nil, .None }
	for entry in checker.procedure_infos {
		if entry.id == id { return entry.info, .None }
	}
	return nil, .Invalid_Id
}
