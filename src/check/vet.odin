package check

import "core:fmt"
import "core:mem"
import "core:slice"
import "oc:syntax"
import "oc:types"

// Locals larger than this get a stack overflow warning, as in the official check_scope_usage.
LARGE_LOCAL_BYTES :: 1 << 18

// Runs the vet checks that need every body checked first. Only files of `package_id` are vetted. A body the checker
// could not finish leaves later names unreferenced, so unused names are only reported when checking had no errors.
check_vet :: proc(checker: ^Expression_Checker, package_id: Package_Id, errors_found: bool) -> Resolve_Error {
	first := len(checker.diagnostics)
	scopes := checker.type_checker.resolver.scopes
	for &entity in scopes.entities {
		if entity.declaration.file == 0 || entity.name == "" || entity.name == "_" { continue }
		if checker.type_checker.files[entity.declaration.file].package_id != package_id { continue }
		#partial switch entity.kind {
		case .Variable:
			check_local_variable(checker, scopes, &entity, first, errors_found) or_return
		case .Import_Name, .Library_Name:
			if !errors_found { check_unused_import(checker, &entity, first) or_return }
		}
	}
	slice.sort_by(checker.diagnostics[first:], proc(a, b: Expression_Diagnostic) -> bool {
		if a.source.file != b.source.file { return a.source.file < b.source.file }
		return a.source.start < b.source.start
	})
	return check_using_shadowing(checker)
}

@(private = "file")
check_local_variable :: proc(checker: ^Expression_Checker, scopes: ^Scope_Store, entity: ^Entity, first: int, errors_found: bool) -> Resolve_Error {
	variable, is_variable := entity.data.(Variable_Data)
	if !is_variable || variable.storage != .Local { return nil }
	if scope := scope_get(scopes, entity.scope); scope == nil || scope.kind != .Block && scope.kind != .Procedure { return nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	if .Used not_in entity.flags && entity.flags & {.Parameter, .Result, .Using, .Field} == {} {
		if checker.options.vet_unused_variables && !errors_found {
			report_vet(checker, first, .Unused, .Error, entity, fmt.aprintf("'%s' declared but not used", entity.name, allocator = allocator)) or_return
		}
		return nil
	}
	if entity.flags & {.Parameter, .Using, .Field} != {} && .Result not_in entity.flags { return nil }
	store := checker.type_checker.store
	size, _, layout_error := types.layout(store, entity.type)
	if layout_error != .None || size <= LARGE_LOCAL_BYTES { return nil }
	reason := fmt.aprintf(
		"Declaration of '%s' may cause a stack overflow due to its type '%s' having a size of %d bytes",
		entity.name,
		types.type_text(store, entity.type, allocator),
		size,
		allocator = allocator,
	)
	return report_vet(checker, first, .Large_Local, .Warning, entity, reason)
}

@(private = "file")
check_unused_import :: proc(checker: ^Expression_Checker, entity: ^Entity, first: int) -> Resolve_Error {
	if !checker.options.vet_unused_imports || .Used in entity.flags || .Export in entity.flags { return nil }
	if library, is_library := entity.data.(Library_Data); is_library && library.used { return nil }
	reason := fmt.aprintf("'%s' declared but not used", entity.name, allocator = mem.dynamic_arena_allocator(&checker.arena))
	return report_vet(checker, first, .Unused, .Error, entity, reason)
}

// Generic instances check one body several times, so a finding at an already reported place is dropped.
@(private = "file")
report_vet :: proc(
	checker: ^Expression_Checker,
	first: int,
	kind: Expression_Diagnostic_Kind,
	severity: Diagnostic_Severity,
	entity: ^Entity,
	reason: string,
) -> Resolve_Error {
	file := checker.type_checker.files[entity.declaration.file]
	node := entity.declaration.node
	if file.ast.nodes[node].kind == .Import_Decl {
		import_decl := syntax.node_payload(file.ast, node, syntax.Import_Decl)
		node = import_decl.name if import_decl.name != 0 else import_decl.relpath
	}
	span := file.ast.nodes[node]
	source := Source_Span{entity.declaration.file, span.start, span.end}
	for existing in checker.diagnostics[first:] {
		if existing.kind == kind && existing.source == source { return nil }
	}
	append(&checker.diagnostics, Expression_Diagnostic{kind = kind, severity = severity, source = source, reason = reason}) or_return
	return nil
}
