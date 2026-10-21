package syntax

import "core:testing"

@(test)
file_tags_preserve_each_directive_token_boundary :: proc(t: ^testing.T) {
	source := transmute([]byte)string("/* #+feature fake */\n#+build ignore\n\n// header comment\n#+feature dynamic-literals\n#+feature using-stmt\n;\npackage sample\n")
	ast: Ast
	ast_init(&ast, context.allocator)
	defer ast_destroy(&ast)
	parser: Parser
	parser_init(&parser, &ast, source)
	defer parser_destroy(&parser)
	parse_file(&parser)
	if !testing.expect_value(t, len(parser.errors), 0) { return }
	file := node_payload(&ast, ast.root, File)
	tags := node_list(&ast, file.tags)
	if !testing.expect_value(t, len(tags), 3) { return }
	expected := [?]string{"#+build ignore", "#+feature dynamic-literals", "#+feature using-stmt"}
	for tag, index in tags {
		span := ast.nodes[tag]
		testing.expect_value(t, string(source[span.start:span.end]), expected[index])
	}
	testing.expect(t, ast.nodes[file.package_decl].start > ast.nodes[tags[2]].end)
}
