package syntax

import "core:strings"
import "core:testing"

@(test)
disallow_do_reports_body_start :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	if true do return
}
`)
	for disallow in ([]bool{false, true}) {
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		parser_init(&parser, &ast, source)
		defer parser_destroy(&parser)
		parser.disallow_do = disallow
		parse_file(&parser)
		if !disallow {
			testing.expect_value(t, len(parser.errors), 0)
			continue
		}
		testing.expect_value(t, len(parser.errors), 1)
		if len(parser.errors) == 1 {
			testing.expect_value(t, parser.errors[0].kind, Parse_Error_Kind.Disallowed_Do)
			testing.expect_value(t, parser.errors[0].offset, u32(strings.index(string(source), "return")))
		}
	}
}
