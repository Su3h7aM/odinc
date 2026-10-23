package syntax

import "core:strings"
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
	on := parse_error_kinds(source, Parse_Options{vet = {.Tabs}})
	defer delete(on)
	testing.expect(t, len(on) == 1 && on[0] == .Tabs_Required, "vet-tabs should report one space-indented statement")
}

@(test)
vet_style_reports_trailing_comma_before_closer :: proc(t: ^testing.T) {
	source := "package sample\nmain :: proc() {\n\t_ = proc(a: int,) {}\n}\n"
	off := parse_error_kinds(source, {})
	defer delete(off)
	testing.expect_value(t, len(off), 0)
	on := parse_error_kinds(source, Parse_Options{vet = {.Style}})
	defer delete(on)
	testing.expect(t, len(on) == 1 && on[0] == .Trailing_Comma_Before_Closer, "vet-style should report a trailing comma before ')' of a parameter list")
	// Only parameter lists report it in the official parser; struct fields and call arguments do not.
	quiet := parse_error_kinds("package sample\nS :: struct { _: [4]u8, }\nmain :: proc() { f(1, ) }\n", Parse_Options{vet = {.Style}})
	defer delete(quiet)
	testing.expect_value(t, len(quiet), 0)
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

@(test)
vet_tags_and_packages_decide_the_flags_of_a_file :: proc(t: ^testing.T) {
	// Official parse_vet_tag applies to the command-line flags; ast_file_vet_flags limits untagged files to -vet-packages.
	options := Parse_Options {
		vet          = {.Shadowing, .Cast},
		vet_packages = {"sample"},
	}
	for row in ([]struct {
			source: string,
			flags:  Vet_Flags,
			errors: int,
			text:   string,
		}{{"package sample\n", {.Shadowing, .Cast}, 0, ""}, {"package other\n", {}, 0, ""}, {"#+vet !cast unused-imports\npackage other\n", {.Shadowing, .Unused_Imports}, 0, ""}, {"#+vet\npackage other\n", {.Shadowing, .Cast} + VET_ALL, 0, ""}, {"#+vet unknown\npackage sample\n", {.Shadowing, .Cast}, 1, "Invalid vet flag name: unknown"}, {"#+vetx\npackage sample\n", {.Shadowing, .Cast}, 1, ""}}) {
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		parser_init(&parser, &ast, transmute([]byte)row.source)
		defer parser_destroy(&parser)
		parser.options = options
		parse_file(&parser)
		testing.expect_value(t, ast.vet, row.flags)
		testing.expect_value(t, len(parser.errors), row.errors)
		if row.text != "" && len(parser.errors) == 1 {
			testing.expect(t, strings.has_prefix(parse_error_text(parser.errors[0]), row.text), parse_error_text(parser.errors[0]))
		}
	}
}
