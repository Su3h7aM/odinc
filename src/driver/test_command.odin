package driver

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:strings"
import "oc:check"
import "oc:ir"
import "oc:link"
import "oc:lower"
import "oc:syntax"
import "oc:types"

Test_Options :: struct {
	all_packages:      bool,
	defines:           map[string]string,
	optimization_mode: check.Optimization_Mode,
	thread_count:      int,
	microarch:         types.X86_Level,
	parse_options:     syntax.Parse_Options,
	check_options:     check.Check_Options,
}

build_tests :: proc(
	odin_root, path: string,
	log: io.Writer,
	allocator: runtime.Allocator,
	options: Test_Options,
	collections: []Collection = nil,
	interpreter: string = link.DEFAULT_INTERPRETER,
) -> (
	image: []byte,
	err: Build_Error,
) {
	session, allocation_error := new(Session, allocator)
	if allocation_error != nil { return nil, allocation_error }
	session.allocator = allocator
	test_options := options
	session.test_options = &test_options
	session.parse_options = options.parse_options
	session.check_options = options.check_options
	defer session_destroy(session)
	file_error: File_Error
	defer file_error_destroy(&file_error, allocator)
	if error := check_session(session, odin_root, path, collections, options.microarch, &file_error); error != .None {
		if session.invalid_test != 0 {
			write_test_signature_error(session, log)
		} else {
			hidden := hide_test_entry_diagnostics(&session.collection.diagnostics, session.test_entry_file)
			hidden = hide_test_entry_diagnostics(&session.resolver.diagnostics, session.test_entry_file) || hidden
			hidden = hide_test_entry_diagnostics(&session.type_checker.diagnostics, session.test_entry_file) || hidden
			hidden = hide_test_entry_diagnostics(&session.checker.diagnostics, session.test_entry_file) || hidden
			write_diagnostics(session, log)
			if hidden { fmt.wprintfln(log, "odinc test: compiler could not check the internal test entry") }
			if file_error.code != nil {
				message := describe_file_error(file_error, allocator)
				defer delete(message, allocator)
				fmt.wprintfln(log, "test build failed: %s", message)
			} else {
				fmt.wprintfln(log, "test build failed: %v", error)
			}
		}
		return nil, error
	}
	write_diagnostics(session, log)
	module: ir.Module
	worker_count := max(options.thread_count, 1)
	errors, lower_error := lower.lower_program(&session.program, &module, allocator, worker_count = worker_count)
	defer delete(errors, allocator)
	if lower_error != nil { return nil, lower_error }
	defer ir.module_destroy(&module)
	if len(errors) != 0 {
		visible := 0
		hidden := false
		for error in errors {
			file := error.source.file
			if error.node.file != 0 { file = error.node.file }
			if file == session.test_entry_file { hidden = true; continue }
			errors[visible] = error
			visible += 1
		}
		write_lower_errors(session, log, errors[:visible])
		if hidden { fmt.wprintfln(log, "odinc test: compiler could not lower the internal test entry") }
		return nil, Lower_Failed{len(errors)}
	}
	entry := session.program.entity_symbols[session.test_entry]
	foreign_files, foreign_err := load_foreign_files(&session.program, session.build.root, allocator)
	if foreign_err != nil {
		write_build_error(log, foreign_err)
		return nil, foreign_err
	}
	defer foreign_files_destroy(&foreign_files)
	return build_image(&module, session.program.symbol_table[entry].name, log, allocator, worker_count, foreign_files, interpreter)
}

@(private)
test_package_name :: proc(session: ^Session, package_id: check.Package_Id) -> string {
	for file in session.files {
		if file == nil || file.package_id != package_id { continue }
		root := syntax.node_payload(file.ast, file.ast.root, syntax.File)
		declaration := syntax.node_payload(file.ast, root.package_decl, syntax.Package_Decl)
		span := file.ast.nodes[declaration.name]
		return string(file.source[span.start:span.end])
	}
	return session.packages[package_id].name
}

@(private = "package")
collect_test_entry :: proc(session: ^Session, main_package: check.Package_Id) -> Driver_Error {
	builder: strings.Builder
	strings.builder_init(&builder, session.allocator)
	defer strings.builder_destroy(&builder)
	name := "__odinc_test_entry"
	for {
		conflict := false
		for declaration in session.collection.declarations {
			entity := check.entity_get(&session.scopes, declaration.entity)
			if entity.package_id == main_package && strings.has_prefix(entity.name, name) { conflict = true; break }
		}
		if !conflict { break }
		owned := fmt.aprintf("%s_", name, allocator = session.allocator)
		if _, error := append(&session.owned_strings, owned); error != nil { return .Allocation_Failed }
		name = owned
	}
	fmt.sbprintf(
		&builder,
		"package %s\nimport %s_testing \"core:testing\"\nimport %s_runtime \"base:runtime\"\n",
		test_package_name(session, main_package),
		name,
		name,
	)
	if session.test_options.all_packages {
		for package_value, index in session.packages {
			if index == 0 || check.Package_Id(index) == main_package { continue }
			has_tests := false
			for declaration in session.collection.declarations {
				entity := check.entity_get(&session.scopes, declaration.entity)
				if entity.package_id == check.Package_Id(index) && .Test in entity.flags { has_tests = true; break }
			}
			if !has_tests { continue }
			fmt.sbprintf(&builder, "import %s_package_%d %q\n", name, index, package_value.key)
		}
	}
	fmt.sbprintf(&builder, "%s :: proc() {{\n %s_tests := []%s_testing.Internal_Test{{\n", name, name, name)
	for declaration in session.collection.declarations {
		entity := check.entity_get(&session.scopes, declaration.entity)
		if .Test not_in entity.flags { continue }
		if entity.package_id != main_package && !session.test_options.all_packages { continue }
		prefix := ""
		if entity.package_id != main_package { prefix = fmt.tprintf("%s_package_%d.", name, entity.package_id) }
		fmt.sbprintf(&builder, "{{%q, %q, %s%s}},\n", test_package_name(session, entity.package_id), entity.name, prefix, entity.name)
	}
	fmt.sbprintf(&builder, "}}\n if !%s_testing.runner(%s_tests) {{ %s_runtime.exit(1) }}\n}}\n", name, name, name)
	text := strings.to_string(builder)
	source, allocation_error := make([]byte, len(text), session.allocator)
	if allocation_error != nil { return .Allocation_Failed }
	copy(source, transmute([]byte)text)
	file_id, load_error := load_source(session, "__$test_entry.odin", source, main_package, session.main_scope)
	if load_error != .None { return load_error }
	session.test_entry_file = file_id
	if check.collect_file(&session.collection, session.files[file_id], file_id, {}) != nil { return .Check_Failed }
	session.test_entry = check.scope_lookup_current(&session.scopes, session.main_scope, name)
	delete_key(&check.scope_get(&session.scopes, session.main_scope).lookup, name)
	entry := check.entity_get(&session.scopes, session.test_entry)
	entry.name = "__$test_entry"
	(&entry.data.(check.Procedure_Data)).source_name = "__$test_entry"
	return .None
}

@(private)
hide_test_entry_diagnostics :: proc(diagnostics: ^[dynamic]$Diagnostic, file: check.File_Id) -> bool {
	if file == 0 { return false }
	hidden := false
	for index := len(diagnostics^) - 1; index >= 0; index -= 1 {
		if diagnostics^[index].source.file == file {
			ordered_remove(diagnostics, index)
			hidden = true
		}
	}
	return hidden
}

@(private = "package")
validate_test_signatures :: proc(session: ^Session, main_package: check.Package_Id) -> Driver_Error {
	expected: types.Type_Id
	for package_value in session.packages {
		if package_value.name != "testing" { continue }
		entity_id := check.scope_lookup_current(&session.scopes, package_value.scope, "Test_Signature")
		if entity_id == 0 { continue }
		if _, error := check.resolve_entity(&session.resolver, entity_id); error != nil { return .Check_Failed }
		expected = check.entity_get(&session.scopes, entity_id).type
		for types.get(&session.store, expected).kind == .Named { expected = types.get(&session.store, expected).elem }
	}
	for declaration in session.collection.declarations {
		entity := check.entity_get(&session.scopes, declaration.entity)
		if .Test not_in entity.flags || (entity.package_id != main_package && !session.test_options.all_packages) { continue }
		if _, error := check.resolve_entity(&session.resolver, declaration.entity); error != nil { return .Check_Failed }
		entity = check.entity_get(&session.scopes, declaration.entity)
		if entity.kind != .Procedure || expected == 0 || !types.are_identical(&session.store, entity.type, expected) {
			session.invalid_test = declaration.entity
			return .Check_Failed
		}
	}
	return .None
}

@(private)
write_test_signature_error :: proc(session: ^Session, writer: io.Writer) {
	entity := check.entity_get(&session.scopes, session.invalid_test)
	file := session.files[entity.declaration.file]
	declaration := syntax.node_payload(file.ast, entity.declaration.node, syntax.Value_Decl)
	position := file.ast.nodes[entity.declaration.node].start
	for name in syntax.node_list(file.ast, declaration.names) {
		span := file.ast.nodes[name]
		if string(file.source[span.start:span.end]) == entity.name { position = span.start; break }
	}
	got := "non-procedure"
	for value in syntax.node_list(file.ast, declaration.values) {
		if file.ast.nodes[value].kind != .Proc_Lit { continue }
		literal := syntax.node_payload(file.ast, value, syntax.Proc_Lit)
		span := file.ast.nodes[literal.type]
		got = strings.trim_space(string(file.source[span.start:span.end]))
		break
	}
	line, column := syntax.line_col(file.lines, position)
	fmt.wprintfln(writer, "%s(%d:%d) Error: Testing procedures must have a signature type of proc(^testing.T), got %s", file.display_path, line, column, got)
}
