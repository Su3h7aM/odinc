package driver

import "core:fmt"
import "core:io"
import "oc:check"
import "oc:lower"

// Writes one line per checker diagnostic as `path:line:column: kind`.
write_diagnostics :: proc(session: ^Session, writer: io.Writer) {
	for diagnostic in session.collection.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, diagnostic.source)
	}
	for diagnostic in session.resolver.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, diagnostic.source)
	}
	for diagnostic in session.type_checker.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, diagnostic.source)
	}
	for diagnostic in session.checker.diagnostics {
		write_diagnostic(session, writer, diagnostic.kind, diagnostic.source)
	}
}

// Writes one line per lowering error as `path:line:column: lower code feature`.
write_lower_errors :: proc(session: ^Session, writer: io.Writer, errors: []lower.Lower_Error) {
	for error in errors {
		file := session.files[error.source.file]
		line, column := line_column(file.source, error.source.start)
		fmt.wprintfln(writer, "%s:%d:%d: lower %v %v", file.display_path, line, column, error.code, error.feature)
	}
}

@(private = "file")
write_diagnostic :: proc(session: ^Session, writer: io.Writer, kind: any, source: check.Source_Span) {
	file := session.files[source.file]
	line, column := line_column(file.source, source.start)
	fmt.wprintfln(writer, "%s:%d:%d: %v", file.display_path, line, column, kind)
}

line_column :: proc(source: []byte, offset: u32) -> (line, column: int) {
	line = 1
	line_start := 0
	for index in 0 ..< min(int(offset), len(source)) {
		if source[index] == '\n' {
			line += 1
			line_start = index + 1
		}
	}
	return line, int(offset) - line_start + 1
}
