package check

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "oc:syntax"
import "oc:types"

// Locals larger than this get a stack overflow warning, as in the official check_scope_usage.
LARGE_LOCAL_BYTES :: 1 << 18

// The vet flags of a file after `#+vet` tags and `-vet-packages` (the official ast_file_vet_flags).
@(private = "package")
file_vet :: proc(checker: ^Expression_Checker, file: File_Id) -> syntax.Vet_Flags {
	return checker.type_checker.files[file].ast.vet
}

// Runs the vet checks that need every body checked first, each against the flags of the file it reports in.
// Library packages are checked lazily, so a declaration that nothing refers to is never checked. Findings about a
// single body hold anywhere, but findings about the use of a whole file (imports) or package (procedures) are
// only sound for `options.complete_package`, where every declaration is checked. A body the checker could not
// finish leaves later names unreferenced, so unused names are only reported when checking had no errors.
check_vet :: proc(checker: ^Expression_Checker, errors_found: bool) -> Resolve_Error {
	first := len(checker.diagnostics)
	scopes := checker.type_checker.resolver.scopes
	for &entity, index in scopes.entities {
		if entity.declaration.file == 0 || entity.name == "" || entity.name == "_" { continue }
		flags := file_vet(checker, entity.declaration.file)
		complete := checker.type_checker.files[entity.declaration.file].package_id == checker.options.complete_package
		#partial switch entity.kind {
		case .Variable:
			check_local_variable(checker, scopes, &entity, flags, first, errors_found) or_return
		case .Import_Name, .Library_Name:
			if complete && !errors_found { check_unused_import(checker, &entity, flags, first) or_return }
		case .Procedure:
			if complete && !errors_found { check_unused_procedure(checker, scopes, &entity, flags, first) or_return }
		}
		if complete { check_when_shadowing(checker, scopes, &entity, Entity_Id(index), flags, first) or_return }
	}
	check_deprecated_imports(checker, first) or_return
	check_deprecated_field_align(checker, first) or_return
	slice.sort_by(checker.diagnostics[first:], proc(a, b: Expression_Diagnostic) -> bool {
		if a.source.file != b.source.file { return a.source.file < b.source.file }
		return a.source.start < b.source.start
	})
	return nil
}

// Follows the official check_scope_usage: one finding per entity, so a name that is both unused and shadowing is
// reported once, and the stack size note only applies to names with neither finding.
@(private = "file")
check_local_variable :: proc(
	checker: ^Expression_Checker,
	scopes: ^Scope_Store,
	entity: ^Entity,
	flags: syntax.Vet_Flags,
	first: int,
	errors_found: bool,
) -> Resolve_Error {
	variable, is_variable := entity.data.(Variable_Data)
	if !is_variable || variable.storage != .Local { return nil }
	if scope := scope_get(scopes, entity.scope); scope == nil || scope.kind != .Block && scope.kind != .Procedure { return nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	unused := flags & syntax.VET_UNUSED != {} && !errors_found
	unused &&= .Used not_in entity.flags && entity.flags & {.Parameter, .Result, .Using, .Field} == {}
	shadowed: ^Entity
	if flags & {.Shadowing, .Using_Stmt, .Using_Param} != {} { shadowed = find_shadowed(checker, scopes, entity) }
	if shadowed != nil {
		line := declaration_line(checker, shadowed)
		if unused {
			reason := fmt.aprintf("'%s' declared but not used, possibly shadows declaration at line %d", entity.name, line, allocator = allocator)
			return report_vet(checker, first, .Unused, .Error, entity, reason)
		}
		using_shadow := .Using in entity.flags
		if using_shadow || .Shadowing in flags {
			format :=
				"Declaration of '%s' from 'using' shadows declaration at line %d" if using_shadow else "Declaration of '%s' shadows declaration at line %d"
			reason := fmt.aprintf(format, entity.name, line, allocator = allocator)
			return report_vet(checker, first, .Shadowing, .Error, entity, reason)
		}
		return nil
	}
	if unused {
		if .Unused_Variables not_in flags { return nil }
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
check_unused_import :: proc(checker: ^Expression_Checker, entity: ^Entity, flags: syntax.Vet_Flags, first: int) -> Resolve_Error {
	if .Unused_Imports not_in flags || .Used in entity.flags || entity.flags & {.Export, .Required} != {} { return nil }
	if library, is_library := entity.data.(Library_Data); is_library && library.used { return nil }
	reason := fmt.aprintf("'%s' declared but not used", entity.name, allocator = mem.dynamic_arena_allocator(&checker.arena))
	return report_vet(checker, first, .Unused, .Error, entity, reason)
}

// The official check_scope_usage with vet_unused_procedures: a procedure nothing refers to is unused unless it is
// `@(require)`, `@(init)`, `@(fini)`, exported, or `main` of the main package. Instances of generic procedures are
// not declarations of their own.
@(private = "file")
check_unused_procedure :: proc(checker: ^Expression_Checker, scopes: ^Scope_Store, entity: ^Entity, flags: syntax.Vet_Flags, first: int) -> Resolve_Error {
	if .Unused_Procedures not_in flags || .Used in entity.flags || entity.flags & {.Required, .Export, .Test} != {} { return nil }
	procedure := entity.data.(Procedure_Data) or_else {}
	if procedure.instance != 0 || procedure.definition != 0 { return nil }
	if scope := scope_get(scopes, entity.scope); scope == nil || scope.kind == .Type_Member { return nil }
	if entity.package_id == checker.options.complete_package && entity.name == "main" { return nil }
	_, is_init := declaration_attribute(checker, entity^, "init") or_return
	_, is_fini := declaration_attribute(checker, entity^, "fini") or_return
	if is_init || is_fini { return nil }
	reason := fmt.aprintf("'%s' declared but not used", entity.name, allocator = mem.dynamic_arena_allocator(&checker.arena))
	return report_vet(checker, first, .Unused, .Error, entity, reason)
}

// A name declared inside a global `when` that hides a package-level or builtin name, as the official
// check_vet_when_shadowing finds it. A name kept in the package scope can only hide a builtin; a file-private one hides
// package-level declarations.
@(private = "file")
check_when_shadowing :: proc(
	checker: ^Expression_Checker,
	scopes: ^Scope_Store,
	entity: ^Entity,
	id: Entity_Id,
	flags: syntax.Vet_Flags,
	first: int,
) -> Resolve_Error {
	if .When_Shadowing not_in flags || .In_When not_in entity.flags || entity.kind == .Import_Name { return nil }
	file_scope := scope_get(scopes, entity.scope)
	outer := file_scope.parent
	if file_scope.lookup[entity.name] != id { outer = scope_get(scopes, outer).parent }
	shadowed_id, found_scope := scope_find(scopes, outer, entity.name)
	shadowed := entity_get(scopes, shadowed_id)
	if shadowed == nil || shadowed_id == id { return nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason: string
	if scope_get(scopes, found_scope).kind == .Universal || shadowed.declaration.file == 0 {
		reason = fmt.aprintf("Declaration of '%s' within a global 'when' shadows the builtin '%s'", entity.name, entity.name, allocator = allocator)
	} else {
		other := checker.type_checker.files[shadowed.declaration.file]
		line, column := syntax.line_col(other.lines, shadowed.order.offset)
		reason = fmt.aprintf(
			"Declaration of '%s' within a global 'when' shadows the declaration at %s(%d:%d)",
			entity.name,
			other.display_path,
			line,
			column,
			allocator = allocator,
		)
	}
	start := entity.order.offset
	return report_at(checker, first, .Shadowing, .Error, {entity.declaration.file, start, start + u32(len(entity.name))}, reason)
}

// `import "core:runtime"`, `core:intrinsics` and `core:builtin` name base packages. The official parser always warns,
// and with the deprecated vet the same text is an error.
@(private = "file")
check_deprecated_imports :: proc(checker: ^Expression_Checker, first: int) -> Resolve_Error {
	for pending in checker.type_checker.collection.pending {
		file := checker.type_checker.files[pending.declaration.file]
		#partial switch pending.kind {
		case .Import:
			path := syntax.node_payload(file.ast, pending.declaration.node, syntax.Import_Decl).relpath
			report_deprecated_import(checker, first, pending.declaration, path) or_return
		case .Foreign_Import:
			paths := syntax.node_payload(file.ast, pending.declaration.node, syntax.Foreign_Import_Decl).fullpaths
			for path in syntax.node_list(file.ast, paths) { report_deprecated_import(checker, first, pending.declaration, path) or_return }
		}
	}
	return nil
}

@(private = "file")
report_deprecated_import :: proc(checker: ^Expression_Checker, first: int, declaration: Node_Ref, path: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[declaration.file]
	text := strings.trim(expression_text(file, path), "\"")
	if !strings.has_prefix(text, "core:") { return nil }
	name := text[len("core:"):]
	if !strings.has_prefix(name, "runtime") && !strings.has_prefix(name, "intrinsics") && !strings.has_prefix(name, "builtin") { return nil }
	severity := Diagnostic_Severity.Error if .Deprecated in file_vet(checker, declaration.file) else .Warning
	reason := fmt.aprintf(
		"import \"core:%s\" has been deprecated in favour of \"base:%s\"",
		name,
		name,
		allocator = mem.dynamic_arena_allocator(&checker.arena),
	)
	span := file.ast.nodes[declaration.node]
	return report_at(checker, first, .Deprecated, severity, {declaration.file, span.start, span.end}, reason)
}

@(private = "file")
check_deprecated_field_align :: proc(checker: ^Expression_Checker, first: int) -> Resolve_Error {
	for file, index in checker.type_checker.files {
		if file == nil { continue }
		for node, node_index in file.ast.nodes {
			if node.kind != .Struct_Type { continue }
			record := syntax.node_payload(file.ast, syntax.Node_Index(node_index), syntax.Struct_Type)
			if record.field_align_pos == 0 { continue }
			start := record.field_align_pos
			report_at(
				checker,
				first,
				.Deprecated,
				.Warning,
				{File_Id(index), start, start + len("field_align")},
				"#field_align has been deprecated in favour of #min_field_align",
			) or_return
		}
	}
	return nil
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
	#partial switch file.ast.nodes[node].kind {
	case .Import_Decl:
		import_decl := syntax.node_payload(file.ast, node, syntax.Import_Decl)
		node = import_decl.name if import_decl.name != 0 else import_decl.relpath
	case .Value_Decl:
		start := entity.order.offset
		return report_at(checker, first, kind, severity, {entity.declaration.file, start, start + u32(len(entity.name))}, reason)
	}
	span := file.ast.nodes[node]
	return report_at(checker, first, kind, severity, {entity.declaration.file, span.start, span.end}, reason)
}

@(private = "file")
report_at :: proc(
	checker: ^Expression_Checker,
	first: int,
	kind: Expression_Diagnostic_Kind,
	severity: Diagnostic_Severity,
	source: Source_Span,
	reason: string,
) -> Resolve_Error {
	for existing in checker.diagnostics[first:] {
		if existing.kind == kind && existing.source == source { return nil }
	}
	append(&checker.diagnostics, Expression_Diagnostic{kind = kind, severity = severity, source = source, reason = reason}) or_return
	return nil
}

// With `#+vet explicit-allocators`, a call may not leave out a parameter whose default is `context.allocator` or
// `context.temp_allocator` (the official check in check_expr.cpp, ast_file_vet_explicit_allocators). Reports the call
// and returns true when the default is such an allocator.
@(private = "package")
vet_implicit_allocator :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	call: syntax.Node_Index,
	default_value: Expression_Ref,
	parameter: Entity_Id,
) -> (
	rejected: bool,
	err: Resolve_Error,
) {
	caller := checker.views[view].file
	if .Explicit_Allocators not_in file_vet(checker, caller) { return false, nil }
	declaring := checker.type_checker.files[checker.views[default_value.view].file]
	if declaring.ast.nodes[default_value.node].kind != .Selector_Expr { return false, nil }
	selector := syntax.node_payload(declaring.ast, default_value.node, syntax.Selector_Expr)
	if declaring.ast.nodes[selector.expr].kind != .Implicit || expression_text(declaring, selector.expr) != "context" { return false, nil }
	field := expression_text(declaring, selector.field)
	if field != "allocator" && field != "temp_allocator" { return false, nil }
	entity := entity_get(checker.type_checker.resolver.scopes, parameter)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	reason := fmt.aprintf(
		"Parameter '%s' of type '%s' must be explicitly provided in procedure call",
		entity.name,
		types.type_text(checker.type_checker.store, entity.type, allocator),
		allocator = allocator,
	)
	span := checker.type_checker.files[caller].ast.nodes[call]
	append(&checker.diagnostics, Expression_Diagnostic{kind = .Explicit_Allocator, source = {caller, span.start, span.end}, reason = reason}) or_return
	return true, nil
}
