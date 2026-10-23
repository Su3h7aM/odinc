package driver

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:slice"
import "core:strings"
import "oc:check"
import "oc:lower"

// Orders source diagnostics as error.cpp does, retaining the first report at a position and merging its extra lines.
write_diagnostics :: proc(session: ^Session, writer: io.Writer, extra: []Output_Diagnostic = nil) {
	if session == nil { return }
	allocator := session.allocator
	if allocator.procedure == nil { allocator = context.allocator }
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&arena)
	scratch := mem.dynamic_arena_allocator(&arena)
	diagnostics, alloc_err := make([dynamic]Output_Diagnostic, 0, scratch)
	if alloc_err != nil { return }
	if unresolved := session.unresolved_when; unresolved.set {
		text := "unresolved when: condition is not a boolean constant"
		if unresolved.reason != nil { text = fmt.aprintf("unresolved when: %v", unresolved.reason, allocator = scratch) }
		diagnostic := source_diagnostic(session, unresolved.source, text)
		if diagnostic.path == "" { diagnostic.path = unresolved.display_path; diagnostic.line = unresolved.line; diagnostic.column = unresolved.column }
		if _, err := append(&diagnostics, diagnostic); err != nil { return }
	}
	for path in session.load_failures {
		found := false
		for diagnostic in session.syntax_diagnostics { if diagnostic.path == path { found = true; break } }
		if !found {
			if _, err := append(&diagnostics, Output_Diagnostic{text = fmt.aprintf("%s: parse failed", path, allocator = scratch)}); err != nil { return }
		}
	}
	for syntax_error in session.syntax_diagnostics {
		diagnostic := Output_Diagnostic {
			path   = syntax_error.path,
			source = syntax_error.source,
			start  = syntax_error.offset,
			end    = token_end_at(syntax_error.source, syntax_error.offset),
			line   = syntax_error.line,
			column = syntax_error.column,
			syntax = true,
			text   = syntax_error.text,
		}
		diagnostic_position(&diagnostic)
		if _, err := append(&diagnostics, diagnostic); err != nil { return }
	}
	if span, found := session.cyclic_import.?; found {
		if _, err := append(&diagnostics, source_diagnostic(session, span, "import cycle")); err != nil { return }
	}
	for item in session.unsupported_imports {
		file := session.files[item.source.file]
		if session.packages[file.package_id].kind == .Runtime { continue }
		text := fmt.aprintf("unsupported import %q", item.path, allocator = scratch)
		if _, err := append(&diagnostics, source_diagnostic(session, item.source, text)); err != nil { return }
	}
	if collect_kind_diagnostics(session, &diagnostics, session.collection.diagnostics[:], scratch) != nil { return }
	if collect_kind_diagnostics(session, &diagnostics, session.resolver.diagnostics[:], scratch) != nil { return }
	for diagnostic in session.type_checker.diagnostics {
		text := diagnostic.reason if diagnostic.reason != "" else fmt.aprint(diagnostic.kind, allocator = scratch)
		if _, err := append(&diagnostics, source_diagnostic(session, diagnostic.source, text)); err != nil { return }
	}
	for diagnostic in session.checker.diagnostics {
		if diagnostic.severity == .Warning && session.check_options.ignore_warnings { continue }
		reason := diagnostic.reason
		if diagnostic.kind == .Conversion && diagnostic.conversion != .None {
			reason =
				fmt.aprintf("%v %s", diagnostic.conversion, reason, allocator = scratch) if reason != "" else fmt.aprint(diagnostic.conversion, allocator = scratch)
		}
		if diagnostic.severity != .Warning && diagnostic.kind not_in check.Message_Diagnostics {
			reason = fmt.aprintf("%v %s", diagnostic.kind, reason, allocator = scratch) if reason != "" else fmt.aprint(diagnostic.kind, allocator = scratch)
		}
		output := source_diagnostic(session, diagnostic.source, reason, diagnostic.severity)
		if _, err := append(&diagnostics, output); err != nil { return }
	}
	for diagnostic in session.analysis_result.diagnostics {
		if diagnostic.severity == .Warning && session.check_options.ignore_warnings { continue }
		if _, err := append(&diagnostics, source_diagnostic(session, diagnostic.source, diagnostic.reason, diagnostic.severity)); err != nil { return }
	}
	if _, err := append(&diagnostics, ..extra); err != nil { return }
	write_ordered_diagnostics(writer, diagnostics[:], session.check_options)
}

@(private = "file")
collect_kind_diagnostics :: proc(
	session: ^Session,
	output: ^[dynamic]Output_Diagnostic,
	diagnostics: []$T,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	for diagnostic in diagnostics {
		text := fmt.aprint(diagnostic.kind, allocator = allocator)
		append(output, source_diagnostic(session, diagnostic.source, text)) or_return
	}
	return nil
}

@(private = "file")
write_ordered_diagnostics :: proc(writer: io.Writer, diagnostics: []Output_Diagnostic, options: check.Check_Options) {
	slice.stable_sort_by(diagnostics, proc(left, right: Output_Diagnostic) -> bool {
		if left.start != right.start { return left.start < right.start }
		if left.line != right.line { return left.line < right.line }
		if left.column != right.column { return left.column < right.column }
		return left.path < right.path
	})
	for index := 0; index < len(diagnostics); {
		first := diagnostics[index]
		write_output_diagnostic(writer, first, options)
		index += 1
		for index < len(diagnostics) {
			next := diagnostics[index]
			if first.path == "" || next.start != first.start || next.line != first.line || next.column != first.column || next.path != first.path { break }
			_, continuation := diagnostic_text_parts(next.text)
			if continuation != "" {
				seen := false
				for previous in diagnostics[:index] {
					if previous.start == first.start && previous.path == first.path && strings.contains(previous.text, continuation) { seen = true; break }
				}
				if !seen { write_diagnostic_lines(writer, continuation) }
			}
			index += 1
		}
	}
}

@(private = "package")
write_message_diagnostic :: proc(
	session: ^Session,
	writer: io.Writer,
	source: check.Source_Span,
	severity: check.Diagnostic_Severity,
	reason: string,
	prefix: string = "",
) {
	write_output_diagnostic(writer, source_diagnostic(session, source, reason, severity, prefix == "Syntax "), session.check_options)
}

write_lower_errors :: proc(session: ^Session, writer: io.Writer, errors: []lower.Lower_Error) {
	for error in errors {
		source := error.source
		if error.node.file != 0 {
			node := session.files[error.node.file].ast.nodes[error.node.node]
			source = {
				file  = error.node.file,
				start = node.start,
				end   = node.end,
			}
		}
		text := fmt.tprintf("lower %v %v", error.code, error.feature)
		if error.code == .Verification && error.verify_code != .None { text = fmt.tprintf("%s %v", text, error.verify_code) }
		write_output_diagnostic(writer, source_diagnostic(session, source, text), session.check_options)
	}
}

@(private = "package")
session_has_errors :: proc(session: ^Session) -> bool {
	if len(session.collection.diagnostics) + len(session.type_checker.diagnostics) + len(session.resolver.diagnostics) != 0 { return true }
	for diagnostic in session.checker.diagnostics {
		if diagnostic.severity == .Error || session.check_options.warnings_as_errors { return true }
	}
	for diagnostic in session.analysis_result.diagnostics {
		if diagnostic.severity == .Error || session.check_options.warnings_as_errors { return true }
	}
	return false
}
