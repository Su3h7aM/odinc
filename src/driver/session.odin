package driver

import "base:runtime"
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

// Heap-allocated: the checkers keep pointers to its fields. Diagnostics stay inspectable after Check_Failed.
Session :: struct {
	allocator:     runtime.Allocator,
	stage:         Session_Stage,
	store:         types.Store,
	builtins:      check.Builtin_Types,
	boolean:       types.Type_Id,
	collections:   Collection_Table,
	constants:     check.Constant_Pool,
	scopes:        check.Scope_Store,
	universe:      check.Scope_Id,
	collection:    check.Collection,
	resolver:      check.Resolver,
	type_checker:  check.Type_Checker,
	checker:       check.Expression_Checker,
	packages:      [dynamic]check.Package,
	files:         [dynamic]^check.File,
	asts:          [dynamic]^syntax.Ast,
	sources:       [dynamic][]byte,
	owned_strings: [dynamic]string,
	program_files: [dynamic]check.File,
	program:       check.Checked_Program,
}

// Checks the main file and the library packages it imports. Imports made by library packages are bound
// unloaded (package 0) and only referenced declarations are resolved. On Check_Failed the session is
// returned so its diagnostics can be inspected; the caller destroys it in every case.
check_program :: proc(odin_root, main_path: string, allocator: runtime.Allocator) -> (session: ^Session, err: Driver_Error) {
	allocated, allocation_error := new(Session, allocator)
	if allocation_error != nil { return nil, .Allocation_Failed }
	session = allocated
	session.allocator = allocator
	err = check_session(session, odin_root, main_path)
	if err != nil && err != .Check_Failed {
		session_destroy(session)
		session = nil
	}
	return session, err
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
		if file != nil { free(file, allocator) }
	}
	for source in session.sources { delete(source, allocator) }
	for text in session.owned_strings { delete(text, allocator) }
	delete(session.packages)
	delete(session.files)
	delete(session.asts)
	delete(session.sources)
	delete(session.owned_strings)
	delete(session.program_files)
	free(session, allocator)
}

@(private = "file")
check_session :: proc(session: ^Session, odin_root, main_path: string) -> Driver_Error {
	allocator := session.allocator
	session.store = types.init()
	session.stage = .Store
	session.stage = .Collections
	if collection_table_init(&session.collections, odin_root, allocator) != .None { return .Collection_Failed }
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

	if error := push(&session.packages, check.Package{}); error != .None { return error }
	if error := push(&session.files, nil); error != .None { return error }
	main_key, key_error := own(session, main_path)
	if key_error != .None { return key_error }
	main_package, main_scope, package_error := add_package(session, main_key, "main", .User)
	if package_error != .None { return package_error }
	main_file, load_error := load_file(session, main_path, main_package, main_scope)
	if load_error != .None { return load_error }
	if check.collect_file(&session.collection, session.files[main_file], main_file, {}) != nil { return .Check_Failed }
	if error := bind_imports(session); error != .None { return error }

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
	session.stage = .Expression_Checker
	if check.expression_checker_init(
		   &session.checker,
		   &session.type_checker,
		   &session.constants,
		   {uintptr = session.builtins.uintptr, layout = types.DEFAULT_LAYOUT},
		   session.builtins.int,
		   session.boolean,
		   allocator,
	   ) !=
	   nil { return .Allocation_Failed }
	session.checker.packages = session.packages[:]

	for declaration in session.collection.declarations {
		if check.entity_get(&session.scopes, declaration.entity).package_id != main_package { continue }
		if _, resolve_error := check.resolve_entity(&session.resolver, declaration.entity); resolve_error != nil { return .Check_Failed }
	}
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
bind_imports :: proc(session: ^Session) -> Driver_Error {
	// Loading appends pending imports, so the count is re-read on every step.
	for index := 0; index < len(session.collection.pending); index += 1 {
		pending := session.collection.pending[index]
		if pending.handled || pending.kind != .Import { continue }
		importer := session.files[pending.declaration.file]
		import_decl := syntax.node_payload(importer.ast, pending.declaration.node, syntax.Import_Decl)
		span := importer.ast.nodes[import_decl.relpath]
		import_path := strings.trim(string(importer.source[span.start:span.end]), "\"")
		package_id, package_error := import_package(session, pending.declaration.file, import_path)
		if package_error != .None { return package_error }
		name := import_path
		if separator := strings.last_index(name, ":"); separator >= 0 { name = name[separator + 1:] }
		if binding_error := check.collect_import_name(&session.collection, importer, index, name, package_id); binding_error != nil { return .Check_Failed }
	}
	return .None
}

@(private = "file")
import_package :: proc(session: ^Session, importer_id: check.File_Id, import_path: string) -> (check.Package_Id, Driver_Error) {
	importer := session.files[importer_id]
	if session.packages[importer.package_id].kind == .Intrinsics { return 0, .None }
	if import_path != "base:intrinsics" { return 0, .Unsupported_Import }
	directory, resolve_error := resolve_collection_import(&session.collections, import_path, filepath.dir(importer.path), session.allocator)
	if resolve_error != .None { return 0, .Import_Failed }
	if error := push(&session.owned_strings, directory); error != .None { return 0, error }
	for package_value, id in session.packages {
		if id != 0 && package_value.key == directory { return check.Package_Id(id), .None }
	}
	package_id, package_scope, package_error := add_package(session, directory, "intrinsics", .Intrinsics)
	if package_error != .None { return 0, package_error }
	return package_id, load_directory(session, directory, package_id, package_scope)
}

@(private = "file")
load_directory :: proc(session: ^Session, directory: string, package_id: check.Package_Id, package_scope: check.Scope_Id) -> Driver_Error {
	handle, open_error := os.open(directory)
	if open_error != nil { return .Import_Failed }
	defer os.close(handle)
	infos, read_error := os.read_dir(handle, -1, session.allocator)
	if read_error != nil { return .Import_Failed }
	defer os.file_info_slice_delete(infos, session.allocator)
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for info in infos {
		if info.type == .Directory || !strings.has_suffix(info.name, ".odin") || strings.has_suffix(info.name, "_test.odin") { continue }
		file_id, load_error := load_file(session, info.fullpath, package_id, package_scope)
		if load_error != .None { return load_error }
		order := check.Source_Order {
			file_order = u32(file_id),
		}
		if check.collect_file(&session.collection, session.files[file_id], file_id, order) != nil { return .Check_Failed }
	}
	return .None
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
	allocator := session.allocator
	source, read_error := os.read_entire_file_from_path(path, allocator)
	if read_error != nil { return 0, .Read_Failed }
	if error := push(&session.sources, source); error != .None { return 0, error }
	ast, ast_error := new(syntax.Ast, allocator)
	if ast_error != nil { return 0, .Allocation_Failed }
	if error := push(&session.asts, ast); error != .None { return 0, error }
	syntax.ast_init(ast, allocator)
	parser: syntax.Parser
	syntax.parser_init(&parser, ast, source, allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	hardcoded := session.packages[package_id].kind == .Intrinsics
	if !hardcoded && len(parser.errors) + len(parser.lex_errors) != 0 { return 0, .Parse_Failed }
	file_scope, scope_error := check.scope_create(&session.scopes, package_scope, .File)
	if scope_error != nil { return 0, .Allocation_Failed }
	file_path, path_error := own(session, path)
	if path_error != .None { return 0, path_error }
	file, file_error := new(check.File, allocator)
	if file_error != nil { return 0, .Allocation_Failed }
	file^ = check.File {
		package_id   = package_id,
		path         = file_path,
		display_path = file_path,
		source       = source,
		ast          = ast,
		scope        = file_scope,
	}
	if error := push(&session.files, file); error != .None { return 0, error }
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
