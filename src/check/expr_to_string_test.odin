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
i :: m[1,2]
j :: struct #packed {a,b:int,c:f32}
k :: enum u8 {A,B=2}
l :: proc(x:int,y:^T)->(r:int)
m :: x if c else y
n :: union #no_nil {int,f32}
o :: bit_field u8 {a:u8|4}
p :: proc() -> !
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
	expected := [?]string {
		"1 + 2",
		`f(x.y, -z, "s")`,
		"xs[1:n]",
		"(a + b) * c",
		"Point{x = 1, y = 2}",
		"cast(f32)i",
		".Red",
		"p^",
		"m[1, 2]",
		"struct #packed {a, b: int, c: f32}",
		"enum u8 {A, B = 2}",
		"proc(x: int, y: ^T) -> (r: int)",
		"x if c else y",
		"union #no_nil {int, f32}",
		"bit_field u8 {a: u8 | 4}",
		"proc()",
	}
	declarations := syntax.node_list(&ast, syntax.node_payload(&ast, ast.root, syntax.File).decls)
	if !testing.expect_value(t, len(declarations), len(expected)) { return }
	for declaration, index in declarations {
		values := syntax.node_list(&ast, syntax.node_payload(&ast, declaration, syntax.Value_Decl).values)
		text := expression_to_string(&file, values[0])
		testing.expectf(t, text == expected[index], "expected %q, got %q", expected[index], text)
	}
	abbreviated := [?]struct {
		index: int,
		text:  string,
	}{{4, "Point{...}"}, {9, "struct #packed {...}"}, {10, "enum u8 {...}"}, {13, "union #no_nil {...}"}, {14, "bit_field  {...}"}}
	for entry in abbreviated {
		values := syntax.node_list(&ast, syntax.node_payload(&ast, declarations[entry.index], syntax.Value_Decl).values)
		text := render_expression(&ast, source, values[0], shorthand = true)
		testing.expectf(t, text == entry.text, "expected %q, got %q", entry.text, text)
	}
}
