package driver

import "core:fmt"
import "core:io"
import "oc:check"
import "oc:lower"
import "oc:syntax"

// Writes one line per checker diagnostic as `path:line:column: kind`, followed by the reason when one is recorded.
write_diagnostics :: proc(session: ^Session, writer: io.Writer) {
	if unresolved := session.unresolved_when; unresolved.set {
		if unresolved.reason == nil {
			fmt.wprintfln(
				writer,
				"%s:%d:%d: unresolved when: condition is not a boolean constant",
				unresolved.display_path,
				unresolved.line,
				unresolved.column,
			)
		} else {
			fmt.wprintfln(writer, "%s:%d:%d: unresolved when: %v", unresolved.display_path, unresolved.line, unresolved.column, unresolved.reason)
		}
	}
	for path in session.load_failures {
		fmt.wprintfln(writer, "%s: parse failed", path)
	}
	if span, found := session.cyclic_import.?; found {
		file := session.files[span.file]
		line, column := syntax.line_col(file.lines, span.start)
		fmt.wprintfln(writer, "%s:%d:%d: import cycle", file.display_path, line, column)
	}
	for item in session.unsupported_imports {
		file := session.files[item.source.file]
		if session.packages[file.package_id].kind == .Runtime { continue }
		line, column := syntax.line_col(file.lines, item.source.start)
		fmt.wprintfln(writer, "%s:%d:%d: unsupported import %q", file.display_path, line, column, item.path)
	}
	for diagnostic in session.collection.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, "", diagnostic.source)
	}
	for diagnostic in session.resolver.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, "", diagnostic.source)
	}
	for diagnostic in session.type_checker.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, "", diagnostic.source)
	}
	for diagnostic in session.checker.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, diagnostic.reason, diagnostic.source)
	}
}

// Writes one line per lowering error as `path:line:column: lower code feature`.
write_lower_errors :: proc(session: ^Session, writer: io.Writer, errors: []lower.Lower_Error) {
	for error in errors {
		source := error.source
		if error.node.file != 0 {
			node := session.files[error.node.file].ast.nodes[error.node.node]
			source = check.Source_Span {
				file  = error.node.file,
				start = node.start,
				end   = node.end,
			}
		}
		if source.file == 0 {
			if error.code == .Verification && error.verify_code != .None {
				fmt.wprintfln(writer, "lower %v %v %v", error.code, error.feature, error.verify_code)
				continue
			}
			fmt.wprintfln(writer, "lower %v %v", error.code, error.feature)
			continue
		}
		file := session.files[source.file]
		line, column := syntax.line_col(file.lines, source.start)
		if error.code == .Verification && error.verify_code != .None {
			fmt.wprintfln(writer, "%s:%d:%d: lower %v %v %v", file.display_path, line, column, error.code, error.feature, error.verify_code)
			continue
		}
		fmt.wprintfln(writer, "%s:%d:%d: lower %v %v", file.display_path, line, column, error.code, error.feature)
	}
}

@(private = "file")
write_diagnostic :: proc(session: ^Session, writer: io.Writer, kind: any, reason: string, source: check.Source_Span) {
	file := session.files[source.file]
	line, column := syntax.line_col(file.lines, source.start)
	if reason == "" {
		fmt.wprintfln(writer, "%s:%d:%d: %v", file.display_path, line, column, kind)
		return
	}
	fmt.wprintfln(writer, "%s:%d:%d: %v %s", file.display_path, line, column, kind, reason)
}
