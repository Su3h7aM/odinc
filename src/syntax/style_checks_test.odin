package syntax

import "core:testing"

@(private = "file")
parse_error_kinds :: proc(source: string, options: Parse_Options) -> [dynamic]Parse_Error_Kind {
	ast: Ast
	ast_init(&ast, context.allocator)
	defer ast_destroy(&ast)
	parser: Parser
	parser_init(&parser, &ast, transmute([]byte)source)
	defer parser_destroy(&parser)
	parser.options = options
	parse_file(&parser)
	kinds: [dynamic]Parse_Error_Kind
	for parse_error in parser.errors {
		append(&kinds, parse_error.kind)
	}
	return kinds
}

@(test)
vet_tabs_reports_space_indentation :: proc(t: ^testing.T) {
	source := "package sample\nmain :: proc() {\n    _ = 1\n}\n"
	off := parse_error_kinds(source, {})
	defer delete(off)
	testing.expect_value(t, len(off), 0)
	on := parse_error_kinds(source, Parse_Options{vet_tabs = true})
	defer delete(on)
	testing.expect(t, len(on) == 1 && on[0] == .Tabs_Required, "vet-tabs should report one space-indented statement")
}

@(test)
vet_style_reports_trailing_comma_before_closer :: proc(t: ^testing.T) {
	source := "package sample\nmain :: proc() {\n\t_ = max(1, 2,)\n}\n"
	off := parse_error_kinds(source, {})
	defer delete(off)
	testing.expect_value(t, len(off), 0)
	on := parse_error_kinds(source, Parse_Options{vet_style = true})
	defer delete(on)
	testing.expect(t, len(on) == 1 && on[0] == .Trailing_Comma_Before_Closer, "vet-style should report a trailing comma before ')' on the same line")
}

@(test)
strict_style_reports_brace_and_semicolon :: proc(t: ^testing.T) {
	sources := [2]string{"package sample\nmain :: proc() {\n\tif true\n\t{\n\t\t_ = 1\n\t}\n}\n", "package sample\nmain :: proc() {\n\t_ = 1;\n}\n"}
	expected := [2]Parse_Error_Kind{.Strict_Brace_Style, .Unneeded_Semicolon}
	for source, index in sources {
		off := parse_error_kinds(source, {})
		defer delete(off)
		testing.expect_value(t, len(off), 0)
		on := parse_error_kinds(source, Parse_Options{strict_style = true})
		defer delete(on)
		testing.expect(t, len(on) == 1 && on[0] == expected[index], "strict-style should report the brace-style or unneeded-semicolon error")
	}
}
