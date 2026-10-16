package syntax

import "core:strings"
import "core:testing"

@(test)
test_ast_dump_binary_value_decl :: proc(test: ^testing.T) {
	source := transmute([]byte)string("x := a + b * 2")

	ast: Ast
	ast_init(&ast)
	defer ast_destroy(&ast)

	x := ast_add_node(&ast, .Ident, 0, 1, Ident{})
	a := ast_add_node(&ast, .Ident, 5, 6, Ident{})
	b := ast_add_node(&ast, .Ident, 9, 10, Ident{})
	two := ast_add_node(&ast, .Basic_Lit, 13, 14, Basic_Lit{kind = .Integer})
	mul := ast_add_node(&ast, .Binary_Expr, 9, 14, Binary_Expr{left = b, op = Token{kind = .Mul, start = 11, end = 12}, right = two})
	add := ast_add_node(&ast, .Binary_Expr, 5, 14, Binary_Expr{left = a, op = Token{kind = .Add, start = 7, end = 8}, right = mul})
	ast.root = ast_add_node(
		&ast,
		.Value_Decl,
		0,
		14,
		Value_Decl{names = ast_add_list(&ast, []Node_Index{x}), values = ast_add_list(&ast, []Node_Index{add}), is_mutable = true},
	)

	dump: strings.Builder
	defer strings.builder_destroy(&dump)
	ast_dump(&ast, source, &dump)

	expected := `Value_Decl 0..14 "x := a + b * 2" is_using=false is_mutable=true
  names[0]: Ident 0..1 "x"
  values[0]: Binary_Expr 5..14 "a + b * 2" op=Add
    left: Ident 5..6 "a"
    right: Binary_Expr 9..14 "b * 2" op=Mul
      left: Ident 9..10 "b"
      right: Basic_Lit 13..14 "2" kind=Integer
`
	testing.expect_value(test, strings.to_string(dump), expected)
}
