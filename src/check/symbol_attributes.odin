package check

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strconv"
import "oc:syntax"

Startup_Candidate :: struct {
	entity: Entity_Id,
	order:  Source_Order,
}

// Text of an attribute on the entity's declaration: "" for a bare attribute, the unquoted string for `name = "text"`.
@(private = "package")
declaration_attribute :: proc(checker: ^Expression_Checker, entity: Entity, name: string) -> (text: string, found: bool, err: runtime.Allocator_Error) {
	if entity.declaration.node == 0 { return "", false, nil }
	file := checker.type_checker.files[entity.declaration.file]
	if file.ast.nodes[entity.declaration.node].kind != .Value_Decl { return "", false, nil }
	decl := syntax.node_payload(file.ast, entity.declaration.node, syntax.Value_Decl)
	for attribute in syntax.node_list(file.ast, decl.attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			identifier := element
			value: syntax.Node_Index
			if file.ast.nodes[element].kind == .Field_Value {
				field := syntax.node_payload(file.ast, element, syntax.Field_Value)
				identifier, value = field.field, field.value
			}
			span := file.ast.nodes[identifier]
			if string(file.source[span.start:span.end]) != name { continue }
			if value == 0 || file.ast.nodes[value].kind != .Basic_Lit { return "", true, nil }
			kind := syntax.node_payload(file.ast, value, syntax.Basic_Lit).kind
			if kind != .String && kind != .Raw_String { return "", true, nil }
			literal := file.ast.nodes[value]
			unquoted, _, ok := strconv.unquote_string(string(file.source[literal.start:literal.end]), mem.dynamic_arena_allocator(&checker.arena))
			if !ok { return "", true, nil }
			return unquoted, true, nil
		}
	}
	return "", false, nil
}

// `link_name` (set at collection, with link_prefix and link_suffix) replaces the name; `export` and foreign declarations keep the bare name. Other symbols are
// package-qualified, so equal names in different packages do not collide at link time.
@(private = "package")
symbol_name :: proc(checker: ^Expression_Checker, program: ^Checked_Program, entity: Entity) -> (name: string, err: runtime.Allocator_Error) {
	if entity.link_name != "" { return entity.link_name, nil }
	if .Export in entity.flags || .Foreign in entity.flags { return entity.name, nil }
	package_name := checker.packages[entity.package_id].name
	bytes := make([]u8, len(package_name) + 1 + len(entity.name), mem.dynamic_arena_allocator(&checker.arena)) or_return
	copy(bytes, package_name)
	bytes[len(package_name)] = '.'
	copy(bytes[len(package_name) + 1:], entity.name)
	return string(bytes), nil
}

@(private = "package")
symbol_linkage :: proc(checker: ^Expression_Checker, entity: Entity) -> (linkage: Linkage, err: runtime.Allocator_Error) {
	text, found := declaration_attribute(checker, entity, "linkage") or_return
	if found {
		switch text {
		case "internal":
			return .Internal, nil
		case "strong":
			return .Strong, nil
		case "weak":
			return .Weak, nil
		case "link_once":
			return .Link_Once, nil
		}
	}
	if .Export in entity.flags { return .Strong, nil }
	if .Private_Package in entity.flags || .Private_File in entity.flags { return .Internal, nil }
	return .Strong, nil
}

// Resolves the `@(init)` and `@(fini)` procedures of every package so they can be published. A runtime procedure that
// fails to check is dropped with its diagnostics: the runtime's startup procedures need constructs not yet supported,
// and programs that do not use them must still build. A failing user procedure makes `valid` false.
resolve_startup_procedures :: proc(checker: ^Expression_Checker) -> (valid: bool, err: Resolve_Error) {
	resolver := checker.type_checker.resolver
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	candidates := make([dynamic]Entity_Id, allocator) or_return
	for entity, id in resolver.scopes.entities {
		if entity.kind != .Procedure { continue }
		_, is_init := declaration_attribute(checker, entity, "init") or_return
		_, is_fini := declaration_attribute(checker, entity, "fini") or_return
		if is_init || is_fini { append(&candidates, Entity_Id(id)) or_return }
	}
	valid = true
	for id in candidates {
		resolver_count := len(resolver.diagnostics)
		type_count := len(checker.type_checker.diagnostics)
		expression_count := len(checker.diagnostics)
		state, resolve_err := resolve_entity(resolver, id)
		if resolve_err != nil { return false, resolve_err }
		failed :=
			state != .Resolved ||
			len(resolver.diagnostics) > resolver_count ||
			len(checker.type_checker.diagnostics) > type_count ||
			len(checker.diagnostics) > expression_count
		if !failed { continue }
		if checker.packages[entity_get(resolver.scopes, id).package_id].kind != .Runtime {
			valid = false
			continue
		}
		for len(resolver.diagnostics) > resolver_count { pop(&resolver.diagnostics) }
		for len(checker.type_checker.diagnostics) > type_count { pop(&checker.type_checker.diagnostics) }
		for len(checker.diagnostics) > expression_count { pop(&checker.diagnostics) }
		entity_get(resolver.scopes, id).state = .Invalid
	}
	return valid, nil
}

// `@(init)` procedures run in source order; `@(fini)` procedures are stored in reverse source order, the order they run.
@(private = "package")
expression_checker_publish_startup :: proc(checker: ^Expression_Checker, program: ^Checked_Program) -> runtime.Allocator_Error {
	scopes := checker.type_checker.resolver.scopes
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	inits := make([dynamic]Startup_Candidate, allocator) or_return
	finis := make([dynamic]Startup_Candidate, allocator) or_return
	for entity, id in scopes.entities {
		if entity.kind != .Procedure || entity.state != .Resolved { continue }
		_, is_init := declaration_attribute(checker, entity, "init") or_return
		_, is_fini := declaration_attribute(checker, entity, "fini") or_return
		order := entity.order
		order.package_order = checker.packages[entity.package_id].init_order
		candidate := Startup_Candidate{Entity_Id(id), order}
		if is_init { append(&inits, candidate) or_return }
		if is_fini { append(&finis, candidate) or_return }
	}
	slice.sort_by(inits[:], startup_candidate_before)
	slice.sort_by(finis[:], startup_candidate_before)
	slice.reverse(finis[:])
	program.runtime.init_procedures = startup_procedures(inits[:], allocator) or_return
	program.runtime.fini_procedures = startup_procedures(finis[:], allocator) or_return
	return nil
}

@(private = "file")
startup_procedures :: proc(candidates: []Startup_Candidate, allocator: runtime.Allocator) -> (procedures: []Ordered_Procedure, err: runtime.Allocator_Error) {
	procedures = make([]Ordered_Procedure, len(candidates), allocator) or_return
	for candidate, index in candidates {procedures[index] = {
			entity = candidate.entity,
		}}
	return procedures, nil
}

@(private = "file")
startup_candidate_before :: proc(left, right: Startup_Candidate) -> bool {
	if left.order.package_order != right.order.package_order { return left.order.package_order < right.order.package_order }
	if left.order.file_order != right.order.file_order { return left.order.file_order < right.order.file_order }
	if left.order.offset != right.order.offset { return left.order.offset < right.order.offset }
	return left.order.declaration_index < right.order.declaration_index
}
