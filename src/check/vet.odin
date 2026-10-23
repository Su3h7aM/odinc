package check

import "core:fmt"
import "core:mem"
import "core:slice"
import "oc:syntax"
import "oc:types"

// Locals larger than this get a stack overflow warning, as in the official check_scope_usage.
LARGE_LOCAL_BYTES :: 1 << 18

// Runs the vet checks that need every body checked first, on the files of `options.vet_package`. A body the checker
// could not finish leaves later names unreferenced, so unused names are only reported when checking had no errors.
check_vet :: proc(checker: ^Expression_Checker, errors_found: bool) -> Resolve_Error {
	first := len(checker.diagnostics)
	scopes := checker.type_checker.resolver.scopes
	for &entity in scopes.entities {
		if entity.declaration.file == 0 || entity.name == "" || entity.name == "_" { continue }
		if !vetted_file(checker, entity.declaration.file) { continue }
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
	return nil
}

@(private = "package")
vetted_file :: proc(checker: ^Expression_Checker, file: File_Id) -> bool {
	return checker.type_checker.files[file].package_id == checker.options.vet_package
}

// Follows the official check_scope_usage: one finding per entity, so a name that is both unused and shadowing is
// reported once, and the stack size note only applies to names with neither finding.
@(private = "file")
check_local_variable :: proc(checker: ^Expression_Checker, scopes: ^Scope_Store, entity: ^Entity, first: int, errors_found: bool) -> Resolve_Error {
	variable, is_variable := entity.data.(Variable_Data)
	if !is_variable || variable.storage != .Local { return nil }
	if scope := scope_get(scopes, entity.scope); scope == nil || scope.kind != .Block && scope.kind != .Procedure { return nil }
	options := checker.options
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	unused := (options.vet_unused_variables || options.vet_unused_imports) && !errors_found
	unused &&= .Used not_in entity.flags && entity.flags & {.Parameter, .Result, .Using, .Field} == {}
	shadowed: ^Entity
	if options.vet_shadowing || options.vet_using_stmt || options.vet_using_param { shadowed = find_shadowed(checker, scopes, entity) }
	if shadowed != nil {
		line := declaration_line(checker, shadowed)
		if unused {
			reason := fmt.aprintf("'%s' declared but not used, possibly shadows declaration at line %d", entity.name, line, allocator = allocator)
			return report_vet(checker, first, .Unused, .Error, entity, reason)
		}
		using_shadow := .Using in entity.flags
		if using_shadow || options.vet_shadowing {
			format :=
				"Declaration of '%s' from 'using' shadows declaration at line %d" if using_shadow else "Declaration of '%s' shadows declaration at line %d"
			reason := fmt.aprintf(format, entity.name, line, allocator = allocator)
			return report_vet(checker, first, .Shadowing, .Error, entity, reason)
		}
		return nil
	}
	if unused {
		if !options.vet_unused_variables { return nil }
		return report_vet(checker, first, .Unused, .Error, entity, fmt.aprintf("'%s' declared but not used", entity.name, allocator = allocator))
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

// The earlier variable of the same type and file that `entity` hides, as the official check_vet_shadowing finds it.
// A body block directly under its procedure scope is the official procedure scope, which is never vetted.
@(private = "file")
find_shadowed :: proc(checker: ^Expression_Checker, scopes: ^Scope_Store, entity: ^Entity) -> ^Entity {
	if .Parameter in entity.flags { return nil }
	scope := scope_get(scopes, entity.scope)
	if scope == nil || scope.kind != .Block { return nil }
	parent := scope_get(scopes, scope.parent)
	if parent == nil || parent.kind != .Block { return nil }
	previous, _ := scope_find(scopes, scope.parent, entity.name)
	shadowed := entity_get(scopes, previous)
	if shadowed == nil || shadowed.kind != .Variable || shadowed.type != entity.type { return nil }
	if shadowed.declaration.file != entity.declaration.file { return nil }
	file := checker.type_checker.files[entity.declaration.file]
	if file.ast.nodes[shadowed.declaration.node].start > file.ast.nodes[entity.declaration.node].start { return nil }
	if .Using not_in entity.flags {
		value := entity.data.(Variable_Data).value
		if value.file != 0 && is_intentional_redeclaration(file, value.node, entity.name) { return nil }
	}
	return shadowed
}

// `x := x` and `x := y if c else x` redeclare on purpose.
@(private = "file")
is_intentional_redeclaration :: proc(file: ^File, value: syntax.Node_Index, name: string) -> bool {
	node := type_unparen(file, value)
	#partial switch file.ast.nodes[node].kind {
	case .Ident:
		return expression_text(file, node) == name
	case .Ternary_If_Expr:
		ternary := syntax.node_payload(file.ast, node, syntax.Ternary_Expr)
		return is_intentional_redeclaration(file, ternary.x, name) || is_intentional_redeclaration(file, ternary.y, name)
	}
	return false
}

@(private = "file")
declaration_line :: proc(checker: ^Expression_Checker, entity: ^Entity) -> u32 {
	file := checker.type_checker.files[entity.declaration.file]
	line, _ := syntax.line_col(file.lines, file.ast.nodes[entity.declaration.node].start)
	return line
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
