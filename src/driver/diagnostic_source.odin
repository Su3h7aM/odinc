package driver

import "core:fmt"
import "core:io"
import "core:strings"
import "core:unicode/utf8"
import "oc:check"
import "oc:syntax"

@(private = "package")
Output_Diagnostic :: struct {
	path:         string,
	source:       []byte,
	start, end:   u32,
	line, column: u32,
	severity:     check.Diagnostic_Severity,
	syntax:       bool,
	text:         string,
}

@(private = "package")
source_diagnostic :: proc(
	session: ^Session,
	span: check.Source_Span,
	text: string,
	severity: check.Diagnostic_Severity = .Error,
	is_syntax: bool = false,
) -> Output_Diagnostic {
	diagnostic := Output_Diagnostic {
		start    = span.start,
		end      = span.end,
		severity = severity,
		syntax   = is_syntax,
		text     = text,
	}
	if span.file == 0 || int(span.file) >= len(session.files) || session.files[span.file] == nil { return diagnostic }
	file := session.files[span.file]
	diagnostic.path = file.display_path
	diagnostic.source = file.source
	diagnostic.line, diagnostic.column = syntax.line_col(file.lines, span.start)
	diagnostic_position(&diagnostic)
	return diagnostic
}

@(private = "package")
diagnostic_position :: proc(diagnostic: ^Output_Diagnostic) {
	if len(diagnostic.source) == 0 {
		if diagnostic.line == 0 { diagnostic.line = 1 }
		if diagnostic.column == 0 { diagnostic.column = diagnostic.start + 1 }
		return
	}
	limit := min(int(diagnostic.start), len(diagnostic.source))
	line_start := 0
	diagnostic.line = 1
	for index := 0; index < limit; index += 1 {
		if diagnostic.source[index] == '\n' {
			diagnostic.line += 1
			line_start = index + 1
		}
	}
	diagnostic.column = u32(utf8.rune_count(string(diagnostic.source[line_start:limit]))) + 1
	if int(diagnostic.start) > limit { diagnostic.column += diagnostic.start - u32(limit) }
}

@(private = "package")
token_end_at :: proc(source: []byte, offset: u32) -> u32 {
	if int(offset) >= len(source) { return offset }
	tokenizer := syntax.init(source[offset:])
	token := syntax.next(&tokenizer)
	if token.start == 0 && token.end > token.start { return offset + token.end }
	return offset
}

@(private = "package")
write_output_diagnostic :: proc(writer: io.Writer, diagnostic: Output_Diagnostic, options: check.Check_Options = {}) {
	if diagnostic.severity == .Warning && options.ignore_warnings { return }
	if diagnostic.path == "" {
		fmt.wprintfln(writer, "%s", diagnostic.text)
		return
	}
	first_line, continuation := diagnostic_text_parts(diagnostic.text)
	label := "Warning" if diagnostic.severity == .Warning && !options.warnings_as_errors else "Error"
	prefix := "Syntax " if diagnostic.syntax else ""
	write_diagnostic_line(writer, fmt.tprintf("%s(%d:%d) %s%s: %s", diagnostic.path, diagnostic.line, diagnostic.column, prefix, label, first_line))
	if !diagnostic.syntax || diagnostic.severity != .Warning || options.warnings_as_errors { write_diagnostic_source(writer, diagnostic) }
	write_diagnostic_lines(writer, continuation)
}

@(private = "package")
diagnostic_text_parts :: proc(text: string) -> (primary, continuation: string) {
	if index := strings.index_byte(text, '\n'); index >= 0 { return text[:index], text[index + 1:] }
	return text, ""
}

@(private = "package")
write_diagnostic_line :: proc(writer: io.Writer, line: string) {
	fmt.wprintf(writer, "%s \n", strings.trim_right_space(line))
}

@(private = "package")
write_diagnostic_lines :: proc(writer: io.Writer, text: string) {
	rest := text
	for rest != "" {
		index := strings.index_byte(rest, '\n')
		if index < 0 {
			write_diagnostic_line(writer, rest)
			return
		}
		write_diagnostic_line(writer, rest[:index])
		rest = rest[index + 1:]
	}
}

@(private = "file")
write_diagnostic_source :: proc(writer: io.Writer, diagnostic: Output_Diagnostic) {
	source := diagnostic.source
	position := min(int(diagnostic.start), len(source))
	if position > 0 && diagnostic.column > 1 && source[position - 1] == '\n' { position -= 1 }
	line_start := position
	if line_start > 0 && line_start < len(source) && source[line_start] == '\n' { line_start -= 1 }
	for line_start > 0 && source[line_start - 1] != '\n' { line_start -= 1 }
	line_end := position
	for line_end < len(source) && source[line_end] != '\n' { line_end += 1 }
	raw_line := string(source[line_start:line_end])
	left_trimmed := strings.trim_left_space(raw_line)
	line_start += len(raw_line) - len(left_trimmed)
	text := strings.trim_right_space(left_trimmed)
	if text == "" {
		write_diagnostic_line(writer, "\t( empty line )")
		return
	}
	start_byte := clamp(position - line_start, 0, len(text))
	graphemes, _, rune_count, width := utf8.decode_grapheme_clusters(text)
	defer delete(graphemes)
	start_grapheme := len(graphemes)
	for grapheme, index in graphemes {
		if grapheme.byte_index == start_byte { start_grapheme = index; break }
	}
	start_rune := rune_count
	if start_grapheme < len(graphemes) { start_rune = graphemes[start_grapheme].rune_index }

	MAX_LINE_WIDTH :: 80
	MAX_TAB_WIDTH :: 8
	ELLIPSIS_PADDING :: 8
	MIN_LEFT_VIEW :: 8
	WINDOW_WIDTH :: MAX_LINE_WIDTH - MAX_TAB_WIDTH - ELLIPSIS_PADDING
	window_start, window_end := 0, len(text)
	if width > WINDOW_WIDTH {
		left_width, right_width, left_grapheme: int
		for index := start_grapheme - 1; index > 0; index -= 1 {
			left_width += graphemes[index].width
			if left_width >= MIN_LEFT_VIEW { left_grapheme = index; window_start = graphemes[index].byte_index; break }
		}
		for index := start_grapheme; index < len(graphemes); index += 1 {
			right_width += graphemes[index].width
			if right_width >= WINDOW_WIDTH - MIN_LEFT_VIEW { window_end = graphemes[index].byte_index; break }
		}
		if right_width < WINDOW_WIDTH - MIN_LEFT_VIEW {
			for index := left_grapheme - 1; index > 0; index -= 1 {
				left_width += graphemes[index].width
				if left_width + right_width >= WINDOW_WIDTH { window_start = graphemes[index].byte_index; break }
			}
		}
	}
	if window_end == 0 { window_end = len(text) }
	padding := 4 if window_start > 0 else 0
	for index := start_grapheme - 1; index >= 0; index -= 1 {
		if graphemes[index].byte_index < window_start { break }
		padding += graphemes[index].width
	}
	range_width := 0
	trailing_range := false
	right_ellipsis := window_end != len(text)
	if diagnostic.end > diagnostic.start {
		end_offset := min(int(diagnostic.end), len(source))
		multiline := false
		for byte in source[position:end_offset] { if byte == '\n' { multiline = true; break } }
		end_rune := start_rune + utf8.rune_count(string(source[position:end_offset]))
		if multiline { right_ellipsis = true }
		for index := start_grapheme; index < len(graphemes); index += 1 {
			grapheme := graphemes[index]
			if !multiline && grapheme.rune_index >= end_rune { break }
			if !multiline && grapheme.byte_index >= window_end { trailing_range = true; break }
			range_width += grapheme.width
			trailing_range = multiline
		}
	}
	range_width = max(range_width, 1)
	fmt.wprint(writer, "\t")
	if window_start > 0 { fmt.wprint(writer, "... ") }
	fmt.wprint(writer, text[window_start:window_end])
	if right_ellipsis { fmt.wprint(writer, " ...") }
	fmt.wprint(writer, " \n\t")
	for _ in 0 ..< padding { fmt.wprint(writer, " ") }
	fmt.wprint(writer, "^")
	for _ in 0 ..< max(range_width - 2, 0) { fmt.wprint(writer, "~") }
	if range_width > 1 { fmt.wprint(writer, "~ ..." if trailing_range else "^") }
	fmt.wprint(writer, " \n")
}
