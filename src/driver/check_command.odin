package driver

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:strings"
import "oc:check"
import "oc:syntax"

// Checks without lowering or writing an output file; diagnostics go to writer.
check_file :: proc(
	odin_root, main_path: string,
	writer: io.Writer,
	allocator: runtime.Allocator,
	no_entry_point: bool,
	collections: []Collection,
	defines: map[string]string,
	parse_options: syntax.Parse_Options = {},
	check_options: check.Check_Options = {},
) -> Driver_Error {
	file_error: File_Error
	defer file_error_destroy(&file_error, allocator)
	session, error := check_program(
		odin_root,
		main_path,
		allocator,
		no_entry_point,
		collections,
		defines,
		file_error = &file_error,
		parse_options = parse_options,
		check_options = check_options,
	)
	defer session_destroy(session)
	if error == .Check_Failed && session != nil {
		_ = check_command_entry_point(session, writer, no_entry_point)
		return .Check_Failed
	}
	if error != .None {
		if session != nil { write_diagnostics(session, writer) }
		if file_error.code != nil {
			message := describe_file_error(file_error, allocator)
			defer delete(message, allocator)
			fmt.wprintfln(writer, "%s", message)
		} else if session == nil {
			fmt.wprintfln(writer, "check failed: %v", error)
		}
		return error
	}
	return check_command_entry_point(session, writer, no_entry_point)
}

@(private = "file")
check_command_entry_point :: proc(session: ^Session, writer: io.Writer, no_entry_point: bool) -> Driver_Error {
	extra: [2]Output_Diagnostic
	count: int
	defer write_diagnostics(session, writer, extra[:count])
	entry := check.scope_lookup_current(&session.scopes, session.main_scope, "main")
	if entry == 0 {
		if no_entry_point { return .None }
		for file, index in session.files {
			if file == nil || session.packages[file.package_id].scope != session.main_scope { continue }
			root := syntax.node_payload(file.ast, file.ast.root, syntax.File)
			position := file.ast.nodes[root.package_decl].start
			extra[count] = source_diagnostic(
				session,
				{file = check.File_Id(index), start = position, end = token_end_at(file.source, position)},
				"Undefined entry point procedure 'main'",
			)
			count += 1
			break
		}
		return .Check_Failed
	}
	entity := check.entity_get(&session.scopes, entry)
	procedure, is_procedure := entity.data.(check.Procedure_Data)
	file := session.files[entity.declaration.file]
	declaration := syntax.node_payload(file.ast, entity.declaration.node, syntax.Value_Decl)
	position := file.ast.nodes[entity.declaration.node].start
	position_end := position
	for name in syntax.node_list(file.ast, declaration.names) {
		span := file.ast.nodes[name]
		if string(file.source[span.start:span.end]) == "main" {
			position = span.start
			position_end = span.end
			break
		}
	}
	name_span := check.Source_Span {
		file  = entity.declaration.file,
		start = position,
		end   = position_end,
	}
	if !is_procedure {
		extra[count] = source_diagnostic(session, name_span, "'main' is reserved as the entry point procedure in the initial scope")
		count += 1
		return .Check_Failed
	}
	if no_entry_point || len(procedure.parameters) == 0 && len(procedure.results) == 0 && procedure.convention == .Odin { return .None }

	if len(procedure.parameters) != 0 || len(procedure.results) != 0 {
		for value in syntax.node_list(file.ast, declaration.values) {
			if file.ast.nodes[value].kind != .Proc_Lit { continue }
			literal := syntax.node_payload(file.ast, value, syntax.Proc_Lit)
			span := file.ast.nodes[literal.type]
			signature := strings.trim_space(string(file.source[span.start:span.end]))
			extra[count] = source_diagnostic(session, name_span, fmt.tprintf("Procedure type of 'main' was expected to be 'proc()', got %s", signature))
			count += 1
			break
		}
	}
	if procedure.convention != .Odin {
		extra[count] = source_diagnostic(session, name_span, "Procedure 'main' cannot have a custom calling convention")
		count += 1
	}
	return .Check_Failed
}
