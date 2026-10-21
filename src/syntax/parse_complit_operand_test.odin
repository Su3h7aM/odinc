package syntax

import "core:testing"

// A composite literal is a binary operand only where `{` can open a literal.
// The official compiler accepts it in value, argument and initializer position
// and rejects it in `if` and `for` conditions, where the `{` opens the body,
// with "Expected 1 expression".
@(test)
composite_literal_as_binary_operand :: proc(t: ^testing.T) {
	accepted := [?]string{`a != [2]int{1, 2}`, `p != Point{1, 2}`, `m != matrix[2, 2]f32{1, 0, 0, 1}`, `a != [2]int{}`, `x != 3`}
	for source in accepted {
		check_binary_complit_operand(t, source, false)
	}
	literal_on_left := [?]string{`[2]int{1, 2} != a`, `matrix[2, 2]f32{1, 0, 0, 1} != m`}
	for source in literal_on_left {
		check_binary_complit_operand(t, source, true)
	}

	accepted_statements := [?]string{`{ ok := a != [2]int{1, 2} }`, `{ _ = take(p != Point{1, 2}) }`, `{ _ = take(m != matrix[2, 2]f32{1, 0, 0, 1}) }`}
	for source in accepted_statements {
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		parse_body_for_test(&parser, &ast, source)
		defer parser_destroy(&parser)
		testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%q: parse errors %v", source, parser.errors)
	}

	rejected_statements := [?]string {
		`{ if a != [2]int{1, 2} {} }`,
		`{ if p != Point{1, 2} {} }`,
		`{ if mat2(q) != mat2{7, 1, 0, 1} {} }`,
		`{ for m != matrix[2, 2]f32{1, 0, 0, 1} {} }`,
	}
	for source in rejected_statements {
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		parse_body_for_test(&parser, &ast, source)
		defer parser_destroy(&parser)
		testing.expectf(
			t,
			len(parser.errors) > 0 && parser.errors[0].kind == .Expected_Single_Expression,
			"%q: expected Expected_Single_Expression, got %v",
			source,
			parser.errors,
		)
	}
}

check_binary_complit_operand :: proc(t: ^testing.T, source: string, literal_on_left: bool) {
	ast: Ast
	ast_init(&ast, context.allocator)
	defer ast_destroy(&ast)
	parser: Parser
	root := parse_expression_for_test(&parser, &ast, source)
	defer parser_destroy(&parser)
	testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%q: parse errors %v", source, parser.errors)
	testing.expectf(t, ast.nodes[root].kind == .Binary_Expr, "%q: expected Binary_Expr, got %v", source, ast.nodes[root].kind)
	if ast.nodes[root].kind != .Binary_Expr {
		return
	}
	binary := node_payload(&ast, root, Binary_Expr)
	operand := binary.right
	if literal_on_left {
		operand = binary.left
	}
	testing.expectf(t, ast.nodes[unparen(&parser, operand)].kind == .Comp_Lit || source == `x != 3`, "%q: expected composite literal operand", source)
}
