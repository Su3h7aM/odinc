package analysis

import "base:runtime"
import "oc:check"
import "oc:types"

@(private = "package")
escape_type :: proc(escape: ^Escape, type: types.Type_Id) -> ^types.Type {
	return types.get(escape.run.program.type_data, types.resolve_named(escape.run.program.type_data, type))
}

@(private = "package")
escape_has_pointers :: proc(escape: ^Escape, type: types.Type_Id) -> bool {
	descriptor := escape_type(escape, type)
	#partial switch descriptor.kind {
	case .Raw_Pointer, .String, .CString, .String16, .CString16, .Any, .Pointer, .Multi_Pointer, .Slice, .Dynamic_Array, .Map, .Soa_Pointer:
		return true
	case .Array, .Enumerated_Array, .Fixed_Capacity_Array, .Simd_Vector:
		return escape_has_pointers(escape, descriptor.elem)
	case .Struct:
		for field in descriptor.fields { if escape_has_pointers(escape, field.type) { return true } }
	case .Union:
		for variant in descriptor.variants { if escape_has_pointers(escape, variant) { return true } }
	case .Tuple:
		for field in descriptor.params { if escape_has_pointers(escape, field) { return true } }
	}
	return false
}

@(private = "package")
escape_plain :: proc(escape: ^Escape, type: types.Type_Id) -> bool {
	descriptor := escape_type(escape, type)
	#partial switch descriptor.kind {
	case .Struct, .Union, .Tuple, .Array, .Enumerated_Array, .Fixed_Capacity_Array:
		return false
	case .Enum, .Bit_Set, .Bit_Field, .Matrix, .Procedure:
		return true
	}
	return !escape_has_pointers(escape, type)
}

@(private = "package")
escape_parameter :: proc(escape: ^Escape, entity: check.Entity_Id) -> bool {
	flags := escape.run.program.entities[entity].flags
	return .Parameter in flags && .Result not_in flags
}

@(private = "package")
escape_local :: proc(escape: ^Escape, entity: check.Entity_Id) -> bool {
	if entity == 0 || escape.run.program.entities[entity].kind != .Variable { return false }
	if .Field in escape.run.program.entities[entity].flags { return false }
	variable, ok := escape.run.program.entities[entity].data.(check.Variable_Data)
	return ok && variable.storage == .Local
}

@(private = "package")
escape_ident_address :: proc(escape: ^Escape, expression: check.Expression_Ref, entity: check.Entity_Id) -> (result: Value_Id, err: runtime.Allocator_Error) {
	if entity == 0 || escape.run.program.entities[entity].kind != .Variable { return }
	if .Field in escape.run.program.entities[entity].flags { return }
	if escape.run.excluded_locals[entity] { return }
	if !escape_local(escape, entity) { return escape_origin_value(escape, expression, {kind = .Outer}) }
	object := escape_object(escape, entity) or_return
	escape.graph.objects[object].address_taken = true
	return escape_origin_value(escape, expression, {kind = .Local, object = object})
}

@(private = "package")
escape_ident_value :: proc(escape: ^Escape, expression: check.Expression_Ref, entity: check.Entity_Id) -> (result: Value_Id, err: runtime.Allocator_Error) {
	if entity == 0 || escape.run.program.entities[entity].kind != .Variable { return }
	if .Field in escape.run.program.entities[entity].flags { return }
	type := escape.run.program.entities[entity].type
	if escape_plain(escape, type) { return }
	if !escape_local(escape, entity) {
		if escape_has_pointers(escape, type) { return escape_origin_value(escape, expression, {kind = .Outer}) }
		return
	}
	object := escape_object(escape, entity) or_return
	if escape_parameter(escape, entity) {
		kind: Origin_Kind = .Variadic if entity == escape.variadic else .Parameter
		return escape_origin_value(escape, expression, {kind = kind, object = object})
	}
	return escape_project(escape, expression, escape.memory[object], 0, read = true)
}

@(private = "package")
escape_load :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	pointer: Value_Id,
	type: types.Type_Id,
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	if type != 0 && !escape_has_pointers(escape, type) { return }
	facts := make([dynamic]Value_Fact, 0, escape.run.allocator) or_return
	for fact in escape_facts(escape, pointer) {
		origin := fact.origin
		#partial switch origin.kind {
		case .Outer:
			escape_add_fact(&facts, {origin = origin}) or_return
		case .Local:
			object := escape.graph.objects[origin.object]
			if escape_parameter(escape, object.entity) {
				origin.kind = .Parameter
				escape_add_fact(&facts, {origin = origin}) or_return
				continue
			}
			fallthrough
		case .Temporary, .Owned:
			for stored in escape_facts(escape, escape.memory[origin.object]) {
				stored := stored
				stored.definite = false
				escape_project_fact(escape, &facts, stored, origin.path) or_return
			}
		case .Variadic:
			descriptor := escape_type(escape, escape.graph.objects[origin.object].type)
			if descriptor.kind != .Slice || escape_type(escape, descriptor.elem).kind != .Any { origin.kind = .Parameter_Load }
			escape_add_fact(&facts, {origin = origin}) or_return
		case .Parameter, .Parameter_Load, .Parameter_Deep:
			origin.kind = .Parameter_Load if origin.kind == .Parameter else .Parameter_Deep
			origin.offset_lost = false
			escape_add_fact(&facts, {origin = origin}) or_return
		}
	}
	return escape_value(escape, .Load, expression, facts[:], []Value_Id{pointer})
}

@(private = "package")
escape_store_memory :: proc(escape: ^Escape, object: Object_Id, path: Path_Id, value: Value_Id, exact: bool = true) -> runtime.Allocator_Error {
	replaces := exact
	for current := path; current != 0; current = escape.graph.paths[current].parent {
		replaces &= escape.graph.paths[current].step.kind != .Element
	}
	if path == 0 && replaces { escape.memory[object] = value; return nil }
	facts := make([dynamic]Value_Fact, 0, escape.run.allocator) or_return
	append(&facts, ..escape_facts(escape, escape.memory[object])) or_return
	if replaces {
		pieces := make([dynamic]Value_Fact, 0, escape.run.allocator) or_return
		for index := len(facts) - 1; index >= 0; index -= 1 {
			fact := facts[index]
			remove := escape_path_has_prefix(escape, fact.path, path)
			if !remove && escape_path_has_prefix(escape, path, fact.path) { remove = escape_split_store(escape, &pieces, fact, path) or_return }
			if remove { unordered_remove(&facts, index) }
		}
		for piece in pieces { escape_add_fact(&facts, piece) or_return }
	}
	for fact in escape_facts(escape, value) {
		fact := fact
		fact.path = escape_path_concat(escape, path, fact.path) or_return
		fact.definite = false
		escape_add_fact(&facts, fact) or_return
	}
	escape.memory[object] = escape_value(escape, .Store, {}, facts[:], []Value_Id{escape.memory[object], value}) or_return
	return nil
}

@(private = "file")
escape_split_store :: proc(escape: ^Escape, facts: ^[dynamic]Value_Fact, fact: Value_Fact, path: Path_Id) -> (result: bool, err: runtime.Allocator_Error) {
	if path == fact.path { return true, nil }
	entry := escape.graph.paths[path]
	if entry.step.kind != .Field { return false, nil }
	descriptor := escape_type(escape, entry.step.owner_type)
	if descriptor.kind != .Struct { return false, nil }
	if entry.parent != fact.path {
		if !(escape_split_store(escape, facts, fact, entry.parent) or_return) { return false, nil }
	}
	for field, index in descriptor.fields {
		if u32(index) == entry.step.field_index || !escape_has_pointers(escape, field.type) { continue }
		piece := fact
		piece.path = escape_path(escape, entry.parent, {kind = .Field, owner_type = entry.step.owner_type, field_index = u32(index)}) or_return
		piece.origin = escape_origin_within(escape, piece.origin, piece.path, escape.graph.paths[fact.path].depth) or_return
		piece.definite = false
		escape_add_fact(facts, piece) or_return
	}
	return true, nil
}

@(private = "package")
escape_store_through :: proc(escape: ^Escape, pointer, value: Value_Id) -> runtime.Allocator_Error {
	facts := escape_facts(escape, pointer)
	for fact in facts {
		#partial switch fact.origin.kind {
		case .Local, .Temporary, .Owned:
			escape_store_memory(escape, fact.origin.object, fact.origin.path, value, len(facts) == 1) or_return
		}
	}
	return nil
}
