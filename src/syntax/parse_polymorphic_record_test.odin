package syntax

import "core:testing"

@(test)
procedure_record_arguments_mark_polymorphic_signatures :: proc(t: ^testing.T) {
	for example in ([?]struct {
			source:   string,
			expected: bool,
		}{{"proc(value: ^Foo($T))", true}, {"proc(value: Foo(T = $T))", true}, {"proc(value: Foo(int))", false}}) {
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		defer parser_destroy(&parser)
		node := parse_expression_for_test(&parser, &ast, example.source)
		if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%s: %v", example.source, parser.errors) { continue }
		testing.expect(t, node_payload(&ast, node, Proc_Type).generic == example.expected)
	}
}
