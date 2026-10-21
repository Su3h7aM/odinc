package check

import "oc:syntax"
import "oc:types"

// `bit_field B { name: T | bits, ... }` over an integer or fixed integer-array backing. Fields are integers, enums or booleans of at most 8 bytes, packed from the least significant bit.
bit_field_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	record := syntax.node_payload(file.ast, node, syntax.Bit_Field_Type)
	store := checker.store
	backing := type_expression(checker, file_id, scope, record.backing_type, false) or_return
	if backing == types.TYPE_POISON { return types.TYPE_POISON, nil }
	backing_type := types.get(store, underlying_type(store, backing))
	backing_kind := backing_type.kind
	if backing_kind == .Array {
		elem_type := types.get(store, underlying_type(store, backing_type.elem))
		if elem_type.kind != .Integer {
			type_report(checker, file_id, file, record.backing_type, .Invalid_Bit_Field_Backing) or_return
			return types.TYPE_POISON, nil
		}
	} else if backing_kind != .Integer {
		type_report(checker, file_id, file, record.backing_type, .Invalid_Bit_Field_Backing) or_return
		return types.TYPE_POISON, nil
	}
	backing_size, _, _ := types.layout(store, backing)
	backing_elem_type := backing_type
	backing_elem_size := backing_size
	if backing_kind == .Array {
		backing_elem_type = types.get(store, underlying_type(store, backing_type.elem))
		backing_elem_size, _, _ = types.layout(store, backing_type.elem)
	}
	nodes := syntax.node_list(file.ast, record.fields)
	fields := make([]types.Type_Field, len(nodes), checker.arena_allocator) or_return
	bit_sizes := make([]u8, len(nodes), checker.arena_allocator) or_return
	count := 0
	total := i64(0)
	valid := true
	for field_node in nodes {
		field := syntax.node_payload(file.ast, field_node, syntax.Bit_Field_Field)
		if file.ast.nodes[field.name].kind != .Ident {
			type_report(checker, file_id, file, field_node, .Invalid_Name) or_return
			valid = false
			continue
		}
		name := expression_text(file, field.name)
		if bit_field_has_field(fields[:count], name) {
			type_report(checker, file_id, file, field.name, .Duplicate_Field, name) or_return
			valid = false
			continue
		}
		field_type := type_expression(checker, file_id, scope, field.type, true) or_return
		if field_type == types.TYPE_POISON {
			valid = false
			continue
		}
		field_kind := types.get(store, underlying_type(store, field_type)).kind
		if field_kind != .Integer && field_kind != .Bool && field_kind != .Enum {
			type_report(checker, file_id, file, field.type, .Invalid_Bit_Field_Field) or_return
			valid = false
			continue
		}
		scalar := field_type
		if field_kind == .Enum { scalar = types.get(store, underlying_type(store, field_type)).backing }
		scalar_type := types.get(store, underlying_type(store, scalar))
		field_size, _, _ := types.layout(store, field_type)
		if field_kind != .Bool && field_size >= 2 && backing_elem_size >= 2 && scalar_type.endianness != backing_elem_type.endianness {
			type_report(checker, file_id, file, field.type, .Unsupported_Type_Expression, "Bit_Field_Endian_Field") or_return
			valid = false
			continue
		}
		if field_size > 8 {
			type_report(checker, file_id, file, field.type, .Invalid_Bit_Field_Field) or_return
			valid = false
			continue
		}
		bit_size, ok := integer_expression(checker, file_id, file, scope, field.bit_size) or_return
		if !ok {
			valid = false
			continue
		}
		if bit_size <= 0 || bit_size > 64 || bit_size > 8 * field_size {
			type_report(checker, file_id, file, field.bit_size, .Invalid_Bit_Field_Field) or_return
			valid = false
			continue
		}
		fields[count] = types.Type_Field {
			name = name,
			type = field_type,
		}
		bit_sizes[count] = u8(bit_size)
		count += 1
		total += bit_size
	}
	// Field-vs-field endian agreement: all fields must share the same endian variety.
	if valid {
		first_field_endian := types.Endian.Native
		have_endian := false
		for i in 0 ..< count {
			descriptor := types.get(store, underlying_type(store, fields[i].type))
			scalar := descriptor
			if descriptor.kind == .Enum { scalar = types.get(store, underlying_type(store, descriptor.backing)) }
			field_size, _, _ := types.layout(store, fields[i].type)
			if descriptor.kind == .Bool || field_size < 2 { continue }
			if !have_endian {
				first_field_endian = scalar.endianness
				have_endian = true
			} else if scalar.endianness != first_field_endian {
				type_report(checker, file_id, file, node, .Unsupported_Type_Expression, "Bit_Field_Endian_Field") or_return
				valid = false
				break
			}
		}
	}
	if valid && total > 8 * backing_size {
		type_report(checker, file_id, file, node, .Bit_Field_Out_Of_Range) or_return
		valid = false
	}
	if !valid { return types.TYPE_POISON, nil }
	return types.intern(store, types.Type{kind = .Bit_Field, backing = backing, fields = fields[:count], bit_sizes = bit_sizes[:count]}), nil
}

@(private = "file")
bit_field_has_field :: proc(fields: []types.Type_Field, name: string) -> bool {
	for field in fields {
		if field.name == name { return true }
	}
	return false
}
