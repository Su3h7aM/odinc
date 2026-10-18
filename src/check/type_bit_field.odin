package check

import "oc:syntax"
import "oc:types"

// `bit_field B { name: T | bits, ... }` over an integer backing. Fields are integers, enums or booleans of at most
// 8 bytes, packed from the least significant bit. Array backings and endian-specific fields are unsupported yet.
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
	backing_kind := types.get(store, underlying_type(store, backing)).kind
	if backing_kind == .Array {
		type_report(checker, file_id, file, record.backing_type, .Unsupported_Type_Expression, "Bit_Field_Array_Backing") or_return
		return types.TYPE_POISON, nil
	}
	if backing_kind != .Integer {
		type_report(checker, file_id, file, record.backing_type, .Invalid_Bit_Field_Backing) or_return
		return types.TYPE_POISON, nil
	}
	backing_size, _, _ := types.layout(store, backing)
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
		if types.get(store, underlying_type(store, scalar)).endianness != .Native {
			type_report(checker, file_id, file, field.type, .Unsupported_Type_Expression, "Bit_Field_Endian_Field") or_return
			valid = false
			continue
		}
		field_size, _, _ := types.layout(store, field_type)
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
