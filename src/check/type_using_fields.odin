package check

import "oc:syntax"
import "oc:types"

@(private = "package")
struct_using_fields_valid :: proc(checker: ^Type_Checker, fields: []types.Type_Field, flags: []syntax.Field_Flags) -> (valid: bool, err: Resolve_Error) {
	names := make([dynamic]string, checker.arena_allocator) or_return
	defer delete(names)
	owners := make([dynamic]types.Type_Id, checker.arena_allocator) or_return
	defer delete(owners)
	return unique_using_field_names(checker, fields, flags, &names, &owners)
}

@(private = "file")
unique_using_field_names :: proc(
	checker: ^Type_Checker,
	fields: []types.Type_Field,
	flags: []syntax.Field_Flags,
	names: ^[dynamic]string,
	owners: ^[dynamic]types.Type_Id,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	for field in fields {
		if field.name == "_" { continue }
		for name in names { if name == field.name { return false, nil } }
		append(names, field.name) or_return
	}
	for field, index in fields {
		if index >= len(flags) || .Using not_in flags[index] { continue }
		owner := types.resolve_named(checker.store, field.type)
		if types.get(checker.store, owner).kind == .Pointer { owner = types.resolve_named(checker.store, types.get(checker.store, owner).elem) }
		descriptor := types.get(checker.store, owner)^
		if descriptor.kind != .Struct { continue }
		recursive := false
		for previous in owners { if previous == owner { recursive = true; break } }
		if recursive {
			for member in descriptor.fields { if member.name != "_" { return false, nil } }
			continue
		}
		append(owners, owner) or_return
		valid = unique_using_field_names(checker, descriptor.fields, checker.field_flags[owner], names, owners) or_return
		pop(owners)
		if !valid { return false, nil }
	}
	return true, nil
}
