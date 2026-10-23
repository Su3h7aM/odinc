package check

import "core:fmt"
import "core:slice"
import "oc:syntax"
import "oc:types"

Foreign_Link_Use :: struct {
	name:   string,
	entity: Entity_Id,
}

// Official check_link_name_uses: foreign procedures sharing a link name must have similar signatures.
@(private = "package")
expression_check_foreign_link_names :: proc(checker: ^Expression_Checker) -> Resolve_Error {
	scopes := checker.type_checker.resolver.scopes
	uses := make([dynamic]Foreign_Link_Use, context.temp_allocator)
	for entity, id in scopes.entities {
		procedure, is_procedure := entity.data.(Procedure_Data)
		if entity.kind != .Procedure || .Foreign not_in entity.flags || !is_procedure || procedure.signature == 0 || entity.state != .Resolved { continue }
		name := entity.link_name if entity.link_name != "" else entity.name
		append(&uses, Foreign_Link_Use{name, Entity_Id(id)}) or_return
	}
	slice.stable_sort_by(uses[:], proc(left, right: Foreign_Link_Use) -> bool { return left.name < right.name })
	store := checker.type_checker.store
	first_index := 0
	for use, index in uses {
		if index == 0 || uses[first_index].name != use.name {
			first_index = index
			continue
		}
		first := uses[first_index]
		first_signature := entity_get(scopes, first.entity).data.(Procedure_Data).signature
		signature := entity_get(scopes, use.entity).data.(Procedure_Data).signature
		if signatures_similar_enough(store, first_signature, signature) { continue }
		declaration := checker.type_checker.declarations[use.entity]
		first_declaration := checker.type_checker.declarations[first.entity]
		first_file := checker.type_checker.files[first_declaration.identifier.file]
		line, column := syntax.line_col(first_file.lines, first_file.ast.nodes[first_declaration.identifier.node].start)
		allocator := checker.type_checker.arena_allocator
		reason := fmt.aprintf(
			"Redeclaration of foreign procedure '%s' with different type signatures\n\tat %s(%d:%d)",
			use.name,
			first_file.path,
			line,
			column,
			allocator = allocator,
		)
		span := checker.type_checker.files[declaration.value.file].ast.nodes[declaration.value.node]
		append(
			&checker.diagnostics,
			Expression_Diagnostic{kind = .Message, source = {declaration.value.file, span.start, span.end}, reason = reason},
		) or_return
	}
	return nil
}

@(private = "file")
signatures_similar_enough :: proc(store: ^types.Store, left_id, right_id: types.Type_Id) -> bool {
	left, right := types.get(store, types.resolve_named(store, left_id)), types.get(store, types.resolve_named(store, right_id))
	if left.kind != .Procedure || right.kind != .Procedure { return true }
	if len(left.params) != len(right.params) || len(left.results) != len(right.results) { return false }
	if left.c_vararg != right.c_vararg || left.variadic != right.variadic { return false }
	for _, index in left.params {
		x, y := left.params[index], right.params[index]
		if left.variadic && index == len(left.params) - 1 {
			x_elem, y_elem := types.get(store, signature_core(store, x)).elem, types.get(store, signature_core(store, y)).elem
			if types.get(store, signature_core(store, x_elem)).kind == .Any || types.get(store, signature_core(store, y_elem)).kind == .Any { continue }
		}
		if !signature_parameter_similar(store, x, y) { return false }
	}
	for _, index in left.results {
		if !signature_parameter_similar(store, left.results[index], right.results[index]) { return false }
	}
	return true
}

// The underlying type; enums and bit sets are spelled by their backing integer.
@(private = "file")
signature_core :: proc(store: ^types.Store, id: types.Type_Id) -> types.Type_Id {
	current := id
	for {
		descriptor := types.get(store, current)
		#partial switch descriptor.kind {
		case .Named:
			current = descriptor.elem
		case .Enum:
			current = descriptor.backing
		case .Bit_Set:
			if descriptor.backing == 0 { return current }
			current = descriptor.backing
		case:
			return current
		}
	}
}

@(private = "file")
signature_parameter_similar :: proc(store: ^types.Store, left, right: types.Type_Id) -> bool {
	x_id, y_id := signature_core(store, left), signature_core(store, right)
	x, y := types.get(store, x_id), types.get(store, y_id)
	same :: proc(a, b: types.Kind, x, y: types.Kind) -> bool { return a == x && b == y || a == y && b == x }
	size_of_type :: proc(store: ^types.Store, id: types.Type_Id) -> i64 {
		size, _, _ := types.layout(store, id)
		return size
	}
	is_u8_pointer :: proc(store: ^types.Store, descriptor: ^types.Type, width: i64) -> bool {
		if descriptor.kind != .Pointer && descriptor.kind != .Multi_Pointer { return false }
		elem := types.get(store, signature_core(store, descriptor.elem))
		return elem.kind == .Integer && !elem.signed && elem.count == width
	}
	kind_x, kind_y := x.kind, y.kind
	switch {
	case kind_x == kind_y && (kind_x == .Pointer || kind_x == .Multi_Pointer || kind_x == .Procedure):
		return true
	case kind_x == .Integer && kind_y == .Integer:
		if size_of_type(store, x_id) == size_of_type(store, y_id) { return true }
	case same(kind_x, kind_y, .Integer, .Bool):
		if size_of_type(store, x_id) == size_of_type(store, y_id) { return true }
	case kind_x == .CString && is_u8_pointer(store, y, 1), kind_y == .CString && is_u8_pointer(store, x, 1):
		return true
	case kind_x == .CString16 && is_u8_pointer(store, y, 2), kind_y == .CString16 && is_u8_pointer(store, x, 2):
		return true
	case same(kind_x, kind_y, .Integer, .Raw_Pointer):
		if x.name == "uintptr" || y.name == "uintptr" { return true }
	case same(kind_x, kind_y, .Procedure, .Pointer), same(kind_x, kind_y, .Pointer, .Multi_Pointer), same(kind_x, kind_y, .Procedure, .Multi_Pointer):
		return true
	case kind_x == .Slice && kind_y == .Slice:
		if signature_parameter_similar(store, x.elem, y.elem) { return true }
	}
	if x_id == y_id { return true }
	if kind_x == .Struct && kind_y == .Struct {
		x_size, x_align, _ := types.layout(store, x_id)
		y_size, y_align, _ := types.layout(store, y_id)
		if x.raw_union == y.raw_union && x_size == y_size && x_align == y_align {
			if x_size > 16 || x.raw_union { return true }
			if len(x.fields) == len(y.fields) {
				for _, index in x.fields {
					if !signature_parameter_similar(store, x.fields[index].type, y.fields[index].type) { return types.are_identical(store, x_id, y_id) }
				}
			}
			return true
		}
	}
	return types.are_identical(store, x_id, y_id)
}
