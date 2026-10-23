package check

import "core:fmt"
import "core:slice"
import "oc:syntax"
import "oc:types"

Link_Name_Kind :: enum u8 {
	Foreign_Procedure,
	Procedure,
	Variable,
}

Link_Name_Use :: struct {
	name:   string,
	kind:   Link_Name_Kind,
	entity: Entity_Id,
}

// Official check_link_name_uses: a link name is reserved or unique per kind, and foreign declarations sharing one
// must have similar types.
@(private = "package")
expression_check_link_names :: proc(checker: ^Expression_Checker) -> Resolve_Error {
	scopes := checker.type_checker.resolver.scopes
	uses := make([dynamic]Link_Name_Use, context.temp_allocator)
	for entity, id in scopes.entities {
		if entity.state != .Resolved { continue }
		kind: Link_Name_Kind
		#partial switch entity.kind {
		case .Procedure:
			procedure, is_procedure := entity.data.(Procedure_Data)
			if !is_procedure || procedure.signature == 0 || procedure.generic { continue }
			if .Foreign in entity.flags {
				kind = .Foreign_Procedure
			} else if entity.link_name != "" || .Export in entity.flags {
				kind = .Procedure
			} else {
				continue
			}
		case .Variable:
			if .Foreign not_in entity.flags && .Export not_in entity.flags || entity.type == 0 { continue }
			kind = .Variable
		case:
			continue
		}
		name := entity.link_name if entity.link_name != "" else entity.name
		append(&uses, Link_Name_Use{name, kind, Entity_Id(id)}) or_return
	}
	slice.stable_sort_by(uses[:], proc(left, right: Link_Name_Use) -> bool {
		if left.name != right.name { return left.name < right.name }
		return left.kind > right.kind
	})
	store := checker.type_checker.store
	allocator := checker.type_checker.arena_allocator
	first_index := 0
	for use, index in uses {
		entity := entity_get(scopes, use.entity)
		if use.name == "main" && use.kind != .Variable {
			runtime_package := use.kind == .Procedure && checker.packages[entity.package_id].kind == .Runtime
			if !runtime_package {
				link_name_report(checker, use.entity, "The link name 'main' is reserved for internal use", use.kind) or_return
			}
			continue
		}
		if index == 0 || uses[first_index].name != use.name {
			first_index = index
			continue
		}
		first := uses[first_index]
		if first.entity == use.entity { continue }
		first_entity := entity_get(scopes, first.entity)
		this_type, other_type := entity.type, first_entity.type
		if use.kind == .Variable || use.kind == .Foreign_Procedure {
			if use.kind == .Foreign_Procedure {
				this_type = entity.data.(Procedure_Data).signature
			}
			if first.kind != .Variable {
				other_type = first_entity.data.(Procedure_Data).signature
			}
		}
		reason: string
		switch use.kind {
		case .Foreign_Procedure:
			this_procedure := types.get(store, types.resolve_named(store, this_type)).kind == .Procedure
			other_procedure := types.get(store, types.resolve_named(store, other_type)).kind == .Procedure
			if this_procedure && other_procedure {
				if signatures_similar_enough(store, other_type, this_type) { continue }
				reason = fmt.aprintf("Redeclaration of foreign procedure '%s' with different type signatures", use.name, allocator = allocator)
			} else {
				if signature_parameter_similar(store, this_type, other_type) { continue }
				reason = fmt.aprintf("Foreign entity '%s' declared elsewhere with a different type", use.name, allocator = allocator)
			}
		case .Procedure:
			reason = fmt.aprintf("Non-unique linking name for procedure '%s'", use.name, allocator = allocator)
		case .Variable:
			if this_type != 0 && other_type != 0 && signature_parameter_similar(store, this_type, other_type) { continue }
			reason = fmt.aprintf("Foreign entity '%s' previously declared elsewhere with a different type", use.name, allocator = allocator)
		}
		other := link_name_position(checker, first.entity)
		label := "other at" if use.kind == .Procedure else "at"
		reason = fmt.aprintf("%s\n\t%s %s", reason, label, other, allocator = allocator)
		link_name_report(checker, use.entity, reason, use.kind) or_return
	}
	return nil
}

@(private = "file")
link_name_position :: proc(checker: ^Expression_Checker, id: Entity_Id) -> string {
	declaration, found := checker.type_checker.declarations[id]
	if !found { return "" }
	file := checker.type_checker.files[declaration.identifier.file]
	line, column := syntax.line_col(file.lines, file.ast.nodes[declaration.identifier.node].start)
	return fmt.aprintf("%s(%d:%d)", file.path, line, column, allocator = checker.type_checker.arena_allocator)
}

// Procedures are reported at their literal, variables at their name.
@(private = "file")
link_name_report :: proc(checker: ^Expression_Checker, id: Entity_Id, reason: string, kind: Link_Name_Kind) -> Resolve_Error {
	declaration, found := checker.type_checker.declarations[id]
	if !found { return nil }
	node := declaration.value if kind != .Variable && declaration.value.node != 0 else declaration.identifier
	span := checker.type_checker.files[node.file].ast.nodes[node.node]
	_, err := append(&checker.diagnostics, Expression_Diagnostic{kind = .Message, source = {node.file, span.start, span.end}, reason = reason})
	return err
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
