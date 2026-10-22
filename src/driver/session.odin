package driver

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "oc:check"
import "oc:syntax"
import "oc:types"

Driver_Error :: enum u8 {
	None,
	Allocation_Failed,
	Collection_Failed,
	Read_Failed,
	Parse_Failed,
	Unsupported_Import,
	Import_Failed,
	Check_Failed,
	Import_Cycle,
	Invalid_Define,
}

// Records how far initialization got, so session_destroy releases exactly what was initialized.
Session_Stage :: enum u8 {
	Empty,
	Store,
	Collections,
	Constants,
	Scopes,
	Collection,
	Resolver,
	Type_Checker,
	Expression_Checker,
}

// An import the driver cannot load, located at its path literal.
Unsupported_Import :: struct {
	path:   string,
	source: check.Source_Span,
}

// An import edge between loaded packages, located at its import declaration.
Import_Edge_Record :: struct {
	from:   check.Package_Id,
	to:     check.Package_Id,
	source: check.Source_Span,
}

// Heap-allocated: the checkers keep pointers to its fields. Diagnostics stay inspectable after Check_Failed.
Session :: struct {
	allocator:           runtime.Allocator,
	stage:               Session_Stage,
	store:               types.Store,
	builtins:            check.Builtin_Types,
	boolean:             types.Type_Id,
	collections:         Collection_Table,
	constants:           check.Constant_Pool,
	scopes:              check.Scope_Store,
	universe:            check.Scope_Id,
	build:               check.Build_Configuration,
	defines:             map[string]string,
	managed_libc:        bool,
	collection:          check.Collection,
	resolver:            check.Resolver,
	type_checker:        check.Type_Checker,
	checker:             check.Expression_Checker,
	packages:            [dynamic]check.Package,
	files:               [dynamic]^check.File,
	asts:                [dynamic]^syntax.Ast,
	sources:             [dynamic][]byte,
	owned_strings:       [dynamic]string,
	unsupported_imports: [dynamic]Unsupported_Import,
	unresolved_when:     Unresolved_When,
	load_failures:       [dynamic]string,
	import_edges:        [dynamic]Import_Edge_Record,
	cyclic_import:       Maybe(check.Source_Span),
	program_files:       [dynamic]check.File,
	program:             check.Checked_Program,
	main_scope:          check.Scope_Id,
	test_options:        ^Test_Options,
	test_entry:          check.Entity_Id,
	test_entry_file:     check.File_Id,
	invalid_test:        check.Entity_Id,
}

// Checks the main file and the library packages it imports. Imports made by library packages are bound
// unloaded (package 0) and only referenced declarations are resolved. On Check_Failed and Unsupported_Import
// the session is returned so its diagnostics can be inspected; the caller destroys it in every case.
check_program :: proc(
	odin_root, main_path: string,
	allocator: runtime.Allocator,
	user_collections: []Collection = nil,
	defines: map[string]string = nil,
) -> (
	session: ^Session,
	err: Driver_Error,
) {
	session, err = check_program_profile(odin_root, main_path, allocator, user_collections, defines, false)
	if session == nil || !session_uses_external_library(session) { return session, err }
	session_destroy(session)
	return check_program_profile(odin_root, main_path, allocator, user_collections, defines, true)
}

// Owned profile first (no libc); a used external library makes check_program recheck with the managed profile.
@(private = "file")
check_program_profile :: proc(
	odin_root, main_path: string,
	allocator: runtime.Allocator,
	user_collections: []Collection,
	defines: map[string]string,
	managed_libc: bool,
) -> (
	session: ^Session,
	err: Driver_Error,
) {
	allocated, allocation_error := new(Session, allocator)
	if allocation_error != nil { return nil, .Allocation_Failed }
	session = allocated
	session.allocator = allocator
	session.defines = defines
	session.managed_libc = managed_libc
	err = check_session(session, odin_root, main_path, user_collections)
	if err != nil && err != .Check_Failed && err != .Unsupported_Import && err != .Parse_Failed && err != .Import_Cycle {
		session_destroy(session)
		session = nil
	}
	return session, err
}

// A used library outside the shipped base/ and core/ trees (system, vendor, or user file) is a real libc bridge.
@(private = "file")
session_uses_external_library :: proc(session: ^Session) -> bool {
	root := session.build.root
	for entity in session.scopes.entities {
		library, is_library := entity.data.(check.Library_Data)
		if !is_library || !library.used { continue }
		for library_path in library.paths {
			if library_is_external(library_path, root) { return true }
		}
	}
	return false
}

// Loads a user program like check_program does, then resolves and checks every declaration of every loaded
// package without stopping at the first error, then lists checker diagnostics and unsupported imports, most
// frequent first, with up to five distinct source lines for each.
program_histogram :: proc(
	odin_root, main_path: string,
	allocator: runtime.Allocator,
	writer: io.Writer,
	user_collections: []Collection = nil,
) -> Driver_Error {
	session, allocation_error := new(Session, allocator)
	if allocation_error != nil { return .Allocation_Failed }
	session.allocator = allocator
	defer session_destroy(session)
	err := program_histogram_collect(session, odin_root, main_path, user_collections)
	print_error := histogram_print(session, writer)
	if err != .None { return err }
	return print_error
}

@(private = "file")
program_histogram_collect :: proc(session: ^Session, odin_root, main_path: string, user_collections: []Collection) -> Driver_Error {
	main_package, _, main_key, load_error := load_main_package(session, odin_root, main_path, user_collections)
	if load_error == .Parse_Failed {
		if error := push(&session.load_failures, main_key); error != .None { return error }
	}
	if load_error != .None { return load_error }
	if check_error := bind_imports(session); check_error != .None { return check_error }
	if check_error := session_init_checkers(session); check_error != .None { return check_error }
	_ = bind_whens(session)
	for declaration in session.collection.declarations {
		if check.entity_get(&session.scopes, declaration.entity).package_id != main_package { continue }
		_, _ = check.resolve_entity(&session.resolver, declaration.entity)
	}
	return .None
}

@(private = "file")
histogram_print :: proc(session: ^Session, writer: io.Writer) -> Driver_Error {
	entries: [dynamic]Histogram_Entry
	defer delete(entries)
	for item in session.unsupported_imports {
		if error := histogram_count(&entries, fmt.tprintf("import %s", item.path), histogram_location(session, item.source)); error != .None {
			return error
		}
	}
	for path in session.load_failures {
		if error := histogram_count(&entries, "load parse", path); error != .None { return error }
	}
	for diagnostic in session.collection.diagnostics {
		if error := histogram_source(&entries, session, "collect", diagnostic.kind, diagnostic.source); error != .None { return error }
	}
	for diagnostic in session.resolver.diagnostics {
		if error := histogram_source(&entries, session, "resolve", diagnostic.kind, diagnostic.source); error != .None { return error }
	}
	for diagnostic in session.type_checker.diagnostics {
		if error := histogram_source(&entries, session, "type", diagnostic.kind, diagnostic.source); error != .None { return error }
	}
	for diagnostic in session.checker.diagnostics {
		reason := diagnostic.reason
		if diagnostic.kind == .Conversion && reason == "" { reason = fmt.tprint(diagnostic.conversion) }
		if error := histogram_source(&entries, session, "expr", diagnostic.kind, diagnostic.source, reason); error != .None { return error }
	}
	slice.sort_by(entries[:], histogram_before)
	total := 0
	for entry in entries { total += entry.count }
	for entry in entries {
		fmt.wprintf(writer, "%d %s\n", entry.count, entry.key)
		for sample_index in 0 ..< entry.sample_count {
			fmt.wprintf(writer, "  %s\n", entry.samples[sample_index])
		}
	}
	fmt.wprintf(writer, "total %d\n", total)
	return .None
}

@(private = "file")
histogram_location :: proc(session: ^Session, source: check.Source_Span) -> string {
	if int(source.file) >= len(session.files) { return "" }
	file := session.files[source.file]
	if file == nil { return "" }
	line, column := syntax.line_col(file.lines, source.start)
	return fmt.tprintf("%s:%d:%d", file.display_path, line, column)
}

session_destroy :: proc(session: ^Session) {
	if session == nil { return }
	allocator := session.allocator
	if session.stage >= .Expression_Checker { check.expression_checker_destroy(&session.checker) }
	if session.stage >= .Type_Checker { check.type_checker_destroy(&session.type_checker) }
	if session.stage >= .Resolver { check.resolver_destroy(&session.resolver) }
	if session.stage >= .Collection { check.collection_destroy(&session.collection) }
	if session.stage >= .Scopes { check.scope_store_destroy(&session.scopes) }
	if session.stage >= .Constants { check.constant_pool_destroy(&session.constants) }
	if session.stage >= .Collections { collection_table_destroy(&session.collections) }
	if session.stage >= .Store { types.destroy(&session.store) }
	for ast in session.asts {
		syntax.ast_destroy(ast)
		free(ast, allocator)
	}
	for file in session.files {
		if file != nil {
			syntax.destroy_line_table(&file.lines)
			free(file, allocator)
		}
	}
	for source in session.sources { delete(source, allocator) }
	for text in session.owned_strings { delete(text, allocator) }
	delete(session.packages)
	delete(session.files)
	delete(session.asts)
	delete(session.sources)
	delete(session.owned_strings)
	delete(session.unsupported_imports)
	delete(session.load_failures)
	delete(session.import_edges)
	delete(session.program_files)
	free(session, allocator)
}

Histogram_Entry :: struct {
	key:          string,
	count:        int,
	samples:      [5]string,
	sample_count: int,
}

@(private = "file")
histogram_before :: proc(a, b: Histogram_Entry) -> bool {
	return a.count > b.count || (a.count == b.count && a.key < b.key)
}

@(private = "file")
histogram_count :: proc(entries: ^[dynamic]Histogram_Entry, key, sample: string) -> Driver_Error {
	for &entry in entries^ {
		if entry.key == key {
			entry.count += 1
			if entry.sample_count == len(entry.samples) { return .None }
			site := sample
			if separator := strings.last_index(sample, ":"); separator >= 0 { site = sample[:separator] }
			for previous in entry.samples[:entry.sample_count] {
				previous_site := previous
				if separator := strings.last_index(previous, ":"); separator >= 0 { previous_site = previous[:separator] }
				if previous_site == site { return .None }
			}
			entry.samples[entry.sample_count] = sample
			entry.sample_count += 1
			return .None
		}
	}
	entry := Histogram_Entry {
		key          = key,
		count        = 1,
		sample_count = 1,
	}
	entry.samples[0] = sample
	return push(entries, entry)
}

@(private = "file")
histogram_source :: proc(
	entries: ^[dynamic]Histogram_Entry,
	session: ^Session,
	stage: string,
	kind: any,
	source: check.Source_Span,
	reason: string = "",
) -> Driver_Error {
	file := session.files[source.file]
	line, column := syntax.line_col(file.lines, source.start)
	name := fmt.tprintf("%v", kind)
	key := fmt.tprintf("%s %s", stage, name)
	switch name {
	case "Unsupported", "Unsupported_Type_Expression":
		key = fmt.tprintf("%s %s", key, span_node_kind(file.ast, source))
	case "Undeclared_Name", "Undeclared_Type":
		key = fmt.tprintf("%s %s", key, string(file.source[source.start:source.end]))
	}
	if reason != "" {
		if name != "Unsupported" && name != "Unsupported_Type_Expression" {
			key = fmt.tprintf("%s %s", key, span_node_kind(file.ast, source))
		}
		key = fmt.tprintf("%s %s", key, reason)
	}
	return histogram_count(entries, key, fmt.tprintf("%s:%d:%d", file.display_path, line, column))
}

// The outermost node with the exact span is the last one, since children are created before their parents.
@(private = "file")
span_node_kind :: proc(ast: ^syntax.Ast, source: check.Source_Span) -> string {
	found := -1
	for node, index in ast.nodes {
		if node.start == source.start && node.end == source.end { found = index }
	}
	if found < 0 { return "no_node" }
	return fmt.tprint(ast.nodes[found].kind)
}

// Prepares the session, loads base:runtime and the main package, and returns the package, its scope and its
// absolute path. A single-file main that fails to parse is left to the caller, which decides whether to record it.
@(private = "package")
load_main_package :: proc(
	session: ^Session,
	odin_root, main_path: string,
	user_collections: []Collection,
) -> (
	package_id: check.Package_Id,
	package_scope: check.Scope_Id,
	main_key: string,
	err: Driver_Error,
) {
	if error := session_prepare(session, odin_root, user_collections); error != .None { return 0, 0, "", error }
	if _, runtime_error := load_runtime(session); runtime_error != .None { return 0, 0, "", runtime_error }
	absolute_key, absolute_error := filepath.abs(main_path, session.allocator)
	if absolute_error != nil { return 0, 0, "", .Read_Failed }
	main_key = absolute_key
	if key_error := push(&session.owned_strings, main_key); key_error != .None { return 0, 0, main_key, key_error }
	main_package, main_scope, package_error := add_package(session, main_key, "main", .User)
	if package_error != .None { return 0, 0, main_key, package_error }
	info, stat_error := os.stat(main_key, session.allocator)
	if stat_error != nil { return 0, 0, main_key, .Read_Failed }
	is_directory := info.type == .Directory
	os.file_info_delete(info, session.allocator)
	if is_directory {
		return main_package, main_scope, main_key, load_package(session, main_key, main_package, main_scope)
	}
	main_file, load_error := load_file(session, main_key, main_package, main_scope)
	if load_error != .None { return main_package, main_scope, main_key, load_error }
	if check.collect_file(&session.collection, session.files[main_file], main_file, {}) != nil {
		return main_package, main_scope, main_key, .Check_Failed
	}
	return main_package, main_scope, main_key, .None
}

@(private = "package")
check_session :: proc(session: ^Session, odin_root, main_path: string, user_collections: []Collection) -> Driver_Error {
	main_package, main_scope, _, load_error := load_main_package(session, odin_root, main_path, user_collections)
	if load_error != .None { return load_error }
	session.main_scope = main_scope
	if error := bind_imports(session); error != .None { return error }
	if len(session.unsupported_imports) != 0 { return .Unsupported_Import }
	if len(session.load_failures) != 0 { return .Parse_Failed }
	if cycle, found := find_import_cycle(session); found {
		session.cyclic_import = cycle
		return .Import_Cycle
	}
	if error := assign_init_order(session); error != .None { return error }
	if error := session_init_checkers(session); error != .None { return error }
	if error := bind_whens(session); error != .None { return error }
	if session.test_options != nil {
		if error := collect_test_entry(session, main_package); error != .None { return error }
		if error := bind_imports(session); error != .None { return error }
		session.type_checker.files = session.files[:]
		session.type_checker.packages = session.packages[:]
		session.checker.packages = session.packages[:]
		if error := bind_whens(session); error != .None { return error }
		if error := assign_init_order(session); error != .None { return error }
		if error := validate_test_signatures(session, main_package); error != .None { return error }
	}

	for declaration in session.collection.declarations {
		if check.entity_get(&session.scopes, declaration.entity).package_id != main_package { continue }
		if _, resolve_error := check.resolve_entity(&session.resolver, declaration.entity); resolve_error != nil { return .Check_Failed }
	}
	directives_valid, directive_error := check.check_package_directives(&session.checker)
	if directive_error != nil || !directives_valid { return .Check_Failed }
	startup_valid, startup_error := check.resolve_startup_procedures(&session.checker)
	if startup_error != nil || !startup_valid { return .Check_Failed }
	if len(session.collection.diagnostics) + len(session.type_checker.diagnostics) + len(session.resolver.diagnostics) + len(session.checker.diagnostics) !=
	   0 {
		return .Check_Failed
	}

	for file in session.files {
		value := check.File{}
		if file != nil { value = file^ }
		if value.policy.division_by_zero == .Unspecified { value.policy.division_by_zero = .Trap }
		if error := push(&session.program_files, value); error != .None { return error }
	}
	session.program.files = session.program_files[:]
	if check.expression_checker_publish_procedures(&session.checker, &session.program) != nil { return .Allocation_Failed }
	return .None
}

@(private = "file")
session_prepare :: proc(session: ^Session, odin_root: string, user_collections: []Collection = nil) -> Driver_Error {
	allocator := session.allocator
	session.store = types.init()
	session.stage = .Store
	session.build = check.DEFAULT_BUILD_CONFIGURATION
	session.build.defines = session.defines
	session.build.no_crt = !session.managed_libc
	if session.test_options != nil {
		session.build.test = true
		session.build.defines = session.test_options.defines
		session.build.optimization_mode = session.test_options.optimization_mode
	}
	session.stage = .Collections
	if collection_table_init(&session.collections, odin_root, allocator) != .None { return .Collection_Failed }
	root := filepath.dir(session.collections.collections[0].path)
	root_path, root_error := strings.concatenate({strings.trim_suffix(root, "/"), "/"}, allocator)
	if root_error != nil { return .Allocation_Failed }
	if error := push(&session.owned_strings, root_path); error != .None { return error }
	session.build.root = root_path
	for collection in user_collections {
		if collection_add(&session.collections, collection.name, collection.path) != .None { return .Collection_Failed }
	}
	collection_table_freeze(&session.collections)
	session.stage = .Constants
	if check.constant_pool_init(&session.constants, allocator) != nil { return .Allocation_Failed }
	session.stage = .Scopes
	if check.scope_store_init(&session.scopes, allocator) != nil { return .Allocation_Failed }
	universe, universe_error := check.scope_create(&session.scopes, 0, .Universal)
	if universe_error != nil { return .Allocation_Failed }
	session.universe = universe
	session.builtins = check.seed_builtin_types(&session.store)
	if check.bind_builtin_types(&session.scopes, universe, session.builtins) != nil { return .Check_Failed }
	if check.bind_universe_builtins(&session.scopes, universe) != nil { return .Check_Failed }
	if !check.bind_universe_constants(&session.scopes, universe, &session.constants) { return .Check_Failed }
	session.boolean = types.intern(&session.store, types.Type{kind = .Bool})
	session.stage = .Collection
	check.collection_init(&session.collection, &session.scopes, allocator)
	session.collection.builtin_scope = universe

	if error := push(&session.packages, check.Package{}); error != .None { return error }
	return push(&session.files, nil)
}

@(private = "file")
session_init_checkers :: proc(session: ^Session) -> Driver_Error {
	allocator := session.allocator
	session.stage = .Resolver
	check.resolver_init(&session.resolver, &session.scopes, check.expression_declaration, &session.checker, allocator)
	session.stage = .Type_Checker
	check.type_checker_init(
		&session.type_checker,
		&session.resolver,
		&session.collection,
		&session.store,
		session.files[:],
		check.expression_integer_evaluator,
		&session.checker,
		allocator,
	)
	session.type_checker.packages = session.packages[:]
	session.stage = .Expression_Checker
	if !check.bind_universe_build_context(&session.type_checker, session.universe, &session.constants, session.build) { return .Check_Failed }
	checker_error := check.expression_checker_init(
		&session.checker,
		&session.type_checker,
		&session.constants,
		{uintptr = session.builtins.uintptr, layout = types.DEFAULT_LAYOUT},
		session.builtins.int,
		session.boolean,
		allocator,
	)
	if checker_error != nil { return .Allocation_Failed }
	session.checker.packages = session.packages[:]
	session.checker.target_features = session.build.target_features
	session.checker.defines = session.build.defines
	return .None
}

// A pending `when` waits for its condition, which needs the expression checker, so it is bound after the checkers exist.
// A condition may name a constant that a later pending `when` declares, so unresolved conditions are retried in passes
// until none progresses. Diagnostics of a failed attempt are dropped; the first unresolved condition is re-evaluated last.
@(private = "file")
bind_whens :: proc(session: ^Session) -> Driver_Error {
	for {
		progressed := false
		first_unresolved := -1
		for index := 0; index < len(session.collection.pending); index += 1 {
			pending := session.collection.pending[index]
			if pending.handled || pending.kind != .When { continue }
			mark := diagnostic_mark(session)
			condition, ok, evaluate_error := evaluate_when(session, pending)
			if evaluate_error != nil {
				record_unresolved_when(session, pending, evaluate_error)
				return .Check_Failed
			}
			if !ok {
				diagnostic_rollback(session, mark)
				if first_unresolved < 0 { first_unresolved = index }
				continue
			}
			file := session.files[pending.declaration.file]
			if check.collect_when_arm(&session.collection, file, index, condition) != nil { return .Check_Failed }
			progressed = true
		}
		if first_unresolved < 0 {
			return .None
		}
		if !progressed {
			pending := session.collection.pending[first_unresolved]
			_, _, reason := evaluate_when(session, pending)
			record_unresolved_when(session, pending, reason)
			return .Check_Failed
		}
	}
}

@(private = "file")
evaluate_when :: proc(session: ^Session, pending: check.Pending_Declaration) -> (condition, ok: bool, err: check.Resolve_Error) {
	file := session.files[pending.declaration.file]
	statement := syntax.node_payload(file.ast, pending.declaration.node, syntax.When_Stmt)
	return session.type_checker.evaluate_boolean(&session.type_checker, file.scope, pending.declaration.file, statement.cond, session.type_checker.user_data)
}

@(private = "file")
Diagnostic_Mark :: struct {
	collection, resolver, type_checker, checker: int,
}

@(private = "file")
diagnostic_mark :: proc(session: ^Session) -> Diagnostic_Mark {
	return {len(session.collection.diagnostics), len(session.resolver.diagnostics), len(session.type_checker.diagnostics), len(session.checker.diagnostics)}
}

@(private = "file")
diagnostic_rollback :: proc(session: ^Session, mark: Diagnostic_Mark) {
	resize(&session.collection.diagnostics, mark.collection)
	resize(&session.resolver.diagnostics, mark.resolver)
	resize(&session.type_checker.diagnostics, mark.type_checker)
	resize(&session.checker.diagnostics, mark.checker)
}

Unresolved_When :: struct {
	set:          bool,
	display_path: string,
	line, column: u32,
	reason:       check.Resolve_Error,
}

@(private = "file")
record_unresolved_when :: proc(session: ^Session, pending: check.Pending_Declaration, reason: check.Resolve_Error) {
	file := session.files[pending.declaration.file]
	line, column := syntax.line_col(file.lines, file.ast.nodes[pending.declaration.node].start)
	session.unresolved_when = Unresolved_When {
		set          = true,
		display_path = file.display_path,
		line         = line,
		column       = column,
		reason       = reason,
	}
}

// Unresolvable imports are recorded and bound unloaded (package 0), so every one is reported in a single run.
@(private = "file")
bind_imports :: proc(session: ^Session) -> Driver_Error {
	// Loading appends pending imports, so the count is re-read on every step.
	for index := 0; index < len(session.collection.pending); index += 1 {
		pending := session.collection.pending[index]
		if pending.handled || pending.kind != .Import { continue }
		importer := session.files[pending.declaration.file]
		import_decl := syntax.node_payload(importer.ast, pending.declaration.node, syntax.Import_Decl)
		span := importer.ast.nodes[import_decl.relpath]
		import_path := strings.trim(string(importer.source[span.start:span.end]), "\"")
		source := check.Source_Span{pending.declaration.file, span.start, span.end}
		package_id, package_error := import_package(session, pending.declaration.file, import_path)
		if package_error == .Allocation_Failed { return package_error }
		if package_error != .None {
			if error := push(&session.unsupported_imports, Unsupported_Import{path = import_path, source = source}); error != .None {
				return error
			}
			package_id = 0
		} else if package_id != 0 && package_id != importer.package_id {
			edge := Import_Edge_Record {
				from   = importer.package_id,
				to     = package_id,
				source = source,
			}
			if error := push(&session.import_edges, edge); error != .None { return error }
		}
		name := import_path
		if separator := strings.last_index(name, ":"); separator >= 0 { name = name[separator + 1:] }
		if separator := strings.last_index(name, "/"); separator >= 0 { name = name[separator + 1:] }
		if binding_error := check.collect_import_name(&session.collection, importer, index, name, package_id); binding_error != nil { return .Check_Failed }
	}
	return .None
}

@(private = "file")
import_package :: proc(session: ^Session, importer_id: check.File_Id, import_path: string) -> (check.Package_Id, Driver_Error) {
	importer := session.files[importer_id]
	if session.packages[importer.package_id].kind == .Intrinsics { return 0, .None }
	if import_path == "base:builtin" || import_path == "core:builtin" { return builtin_package(session) }
	directory, resolve_error := import_directory(&session.collections, import_path, filepath.dir(importer.path), session.allocator)
	if resolve_error != .None { return 0, .Import_Failed }
	if error := push(&session.owned_strings, directory); error != .None { return 0, error }
	for package_value, id in session.packages {
		if id != 0 && package_value.key == directory { return check.Package_Id(id), .None }
	}
	kind := check.Package_Kind.User
	if import_path == "base:intrinsics" || import_path == "core:intrinsics" { kind = .Intrinsics }
	package_id, package_scope, package_error := add_package(session, directory, filepath.base(directory), kind)
	if package_error != .None { return 0, package_error }
	return package_id, load_package(session, directory, package_id, package_scope)
}

// Loads every target-selected .odin file of a directory. A file that fails to parse is recorded and skipped,
// so all parse failures of a run are reported together.
@(private = "file")
load_package :: proc(session: ^Session, directory: string, package_id: check.Package_Id, package_scope: check.Scope_Id) -> Driver_Error {
	handle, open_error := os.open(directory)
	if open_error != nil { return .Import_Failed }
	defer os.close(handle)
	infos, read_error := os.read_dir(handle, -1, session.allocator)
	if read_error != nil { return .Import_Failed }
	defer os.file_info_slice_delete(infos, session.allocator)
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	loaded := 0
	for info in infos {
		if info.type == .Directory ||
		   !strings.has_suffix(info.name, ".odin") ||
		   (session.test_options == nil && strings.has_suffix(info.name, "_test.odin")) { continue }
		source, source_error := os.read_entire_file_from_path(info.fullpath, session.allocator)
		if source_error != nil { return .Read_Failed }
		hardcoded := session.packages[package_id].kind == .Intrinsics
		if !hardcoded && target_source_excluded(info.name, string(source)) {
			delete(source, session.allocator)
			continue
		}
		file_id, load_error := load_source(session, info.fullpath, source, package_id, package_scope)
		if load_error == .Parse_Failed {
			failed_path, path_error := own(session, info.fullpath)
			if path_error != .None { return path_error }
			if error := push(&session.load_failures, failed_path); error != .None { return error }
			continue
		}
		if load_error != .None { return load_error }
		loaded += 1
		order := check.Source_Order {
			file_order = u32(file_id),
		}
		if check.collect_file(&session.collection, session.files[file_id], file_id, order) != nil { return .Check_Failed }
	}
	if loaded == 0 { return .Import_Failed }
	return .None
}

// base:builtin names the universal scope, as checker.cpp builtin_pkg does: its members are the universe builtins.
@(private = "file")
builtin_package :: proc(session: ^Session) -> (check.Package_Id, Driver_Error) {
	for package_value, id in session.packages {
		if id != 0 && package_value.kind == .Builtin { return check.Package_Id(id), .None }
	}
	if error := push(&session.packages, check.Package{key = "builtin", name = "builtin", kind = .Builtin, scope = session.universe}); error != .None {
		return 0, error
	}
	return check.Package_Id(len(session.packages) - 1), .None
}

// Depth-first search over the import edges. An edge into a package still on the search path closes a cycle.
@(private = "file")
find_import_cycle :: proc(session: ^Session) -> (source: check.Source_Span, found: bool) {
	states := make([]u8, len(session.packages), context.temp_allocator)
	for id in 1 ..< len(session.packages) {
		source, found = find_cycle_from(session, states, check.Package_Id(id))
		if found { return }
	}
	return {}, false
}

@(private = "file")
find_cycle_from :: proc(session: ^Session, states: []u8, package_id: check.Package_Id) -> (source: check.Source_Span, found: bool) {
	states[package_id] = 1
	for edge in session.import_edges {
		if edge.from != package_id { continue }
		if states[edge.to] == 1 { return edge.source, true }
		if states[edge.to] == 0 {
			source, found = find_cycle_from(session, states, edge.to)
			if found { return }
		}
	}
	states[package_id] = 2
	return {}, false
}

// Numbers the packages so that each one follows the packages it imports, in import order: the order of `@(init)`
// procedures and of dynamic package variables.
@(private = "file")
assign_init_order :: proc(session: ^Session) -> Driver_Error {
	visited, allocate_error := make([]bool, len(session.packages), session.allocator)
	if allocate_error != nil { return .Allocation_Failed }
	defer delete(visited, session.allocator)
	next: u32
	for id in 0 ..< len(session.packages) {
		next = visit_init_order(session, visited, check.Package_Id(id), next)
	}
	return .None
}

@(private = "file")
visit_init_order :: proc(session: ^Session, visited: []bool, package_id: check.Package_Id, next: u32) -> u32 {
	if visited[package_id] { return next }
	visited[package_id] = true
	next := next
	for edge in session.import_edges {
		if edge.from == package_id { next = visit_init_order(session, visited, edge.to, next) }
	}
	session.packages[package_id].init_order = next
	return next + 1
}

@(private = "file")
// base:runtime is loaded for every program: its @(builtin) declarations form the universal scope.
load_runtime :: proc(session: ^Session) -> (check.Package_Id, Driver_Error) {
	directory, resolve_error := resolve_collection_import(&session.collections, "base:runtime", "", session.allocator)
	if resolve_error != .None { return 0, .Import_Failed }
	if error := push(&session.owned_strings, directory); error != .None { return 0, error }
	runtime_package, runtime_scope, package_error := add_package(session, directory, "runtime", .Runtime)
	if package_error != .None { return 0, package_error }
	session.collection.runtime_package = runtime_package
	session.collection.runtime_scope = runtime_scope
	return runtime_package, load_package(session, directory, runtime_package, runtime_scope)
}

@(private = "file")
add_package :: proc(session: ^Session, key, name: string, kind: check.Package_Kind) -> (check.Package_Id, check.Scope_Id, Driver_Error) {
	scope, scope_error := check.scope_create(&session.scopes, session.universe, .Package)
	if scope_error != nil { return 0, 0, .Allocation_Failed }
	if error := push(&session.packages, check.Package{key = key, name = name, kind = kind, scope = scope}); error != .None { return 0, 0, error }
	return check.Package_Id(len(session.packages) - 1), scope, .None
}

@(private = "file")
load_file :: proc(session: ^Session, path: string, package_id: check.Package_Id, package_scope: check.Scope_Id) -> (check.File_Id, Driver_Error) {
	source, read_error := os.read_entire_file_from_path(path, session.allocator)
	if read_error != nil { return 0, .Read_Failed }
	return load_source(session, path, source, package_id, package_scope)
}

// Takes ownership of source.
@(private = "package")
load_source :: proc(
	session: ^Session,
	path: string,
	source: []byte,
	package_id: check.Package_Id,
	package_scope: check.Scope_Id,
) -> (
	check.File_Id,
	Driver_Error,
) {
	if error := push(&session.sources, source); error != .None { return 0, error }
	ast, has_errors, parse_error := parse_source(source, session.allocator)
	if ast != nil {
		if error := push(&session.asts, ast); error != .None { return 0, error }
	}
	if parse_error != .None { return 0, parse_error }
	hardcoded := session.packages[package_id].kind == .Intrinsics
	if !hardcoded && has_errors { return 0, .Parse_Failed }
	return add_file(session, path, source, ast, package_id, package_scope)
}

// Parses source into a new ast that refers to source, so the caller keeps source alive.
@(private = "file")
parse_source :: proc(source: []byte, allocator: runtime.Allocator) -> (ast: ^syntax.Ast, has_errors: bool, err: Driver_Error) {
	allocated, allocation_error := new(syntax.Ast, allocator)
	if allocation_error != nil { return nil, false, .Allocation_Failed }
	syntax.ast_init(allocated, allocator)
	parser: syntax.Parser
	syntax.parser_init(&parser, allocated, source, allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	return allocated, len(parser.errors) + len(parser.lex_errors) != 0, .None
}

@(private = "file")
add_file :: proc(
	session: ^Session,
	path: string,
	source: []byte,
	ast: ^syntax.Ast,
	package_id: check.Package_Id,
	package_scope: check.Scope_Id,
) -> (
	check.File_Id,
	Driver_Error,
) {
	file_scope, scope_error := check.scope_create(&session.scopes, package_scope, .File)
	if scope_error != nil { return 0, .Allocation_Failed }
	file_path, path_error := own(session, path)
	if path_error != .None { return 0, path_error }
	file, file_error := new(check.File, session.allocator)
	if file_error != nil { return 0, .Allocation_Failed }
	lines, lines_error := syntax.make_line_table(source, session.allocator)
	if lines_error != nil {
		free(file, session.allocator)
		return 0, .Allocation_Failed
	}
	file^ = check.File {
		package_id   = package_id,
		path         = file_path,
		display_path = file_path,
		source       = source,
		lines        = lines,
		ast          = ast,
		scope        = file_scope,
	}
	if error := push(&session.files, file); error != .None {
		syntax.destroy_line_table(&file.lines)
		free(file, session.allocator)
		return 0, error
	}
	return check.File_Id(len(session.files) - 1), .None
}

@(private = "file")
push :: proc(array: ^[dynamic]$E, value: E) -> Driver_Error {
	if _, error := append(array, value); error != nil { return .Allocation_Failed }
	return .None
}

@(private = "file")
own :: proc(session: ^Session, text: string) -> (string, Driver_Error) {
	owned, error := strings.clone(text, session.allocator)
	if error != nil { return "", .Allocation_Failed }
	if push_error := push(&session.owned_strings, owned); push_error != .None {
		delete(owned, session.allocator)
		return "", push_error
	}
	return owned, .None
}
