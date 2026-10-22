package check

import "core:testing"
import "oc:syntax"

// Each constant declaration holds one expression; the rendering matches official expr_to_string.
@(test)
expression_to_string_renders_like_official :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
a :: 1+2
b :: f(x.y,-z,"s")
c :: xs[1:n]
d :: (a+b)*c
e :: Point{x=1,y=2}
f :: cast(f32)i
g :: .Red
h :: p^
`,
	)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expect(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0) { return }

	file := File {
		source = source,
		ast    = &ast,
	}
	expected := [?]string{"1 + 2", `f(x.y, -z, "s")`, "xs[1:n]", "(a + b) * c", "Point{x = 1, y = 2}", "cast(f32)i", ".Red", "p^"}
	declarations := syntax.node_list(&ast, syntax.node_payload(&ast, ast.root, syntax.File).decls)
	if !testing.expect_value(t, len(declarations), len(expected)) { return }
	for declaration, index in declarations {
		values := syntax.node_list(&ast, syntax.node_payload(&ast, declaration, syntax.Value_Decl).values)
		text := expression_to_string(&file, values[0])
		testing.expectf(t, text == expected[index], "expected %q, got %q", expected[index], text)
	}
}
