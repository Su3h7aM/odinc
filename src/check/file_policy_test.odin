package check

import "core:testing"
import "oc:syntax"

@(test)
file_features_come_from_parsed_tags_and_preserve_supplied_policy :: proc(t: ^testing.T) {
	source := transmute([]byte)string("/*\n#+feature using-stmt\n*/\n#+feature global-context /* using-stmt */\n#+feature dynamic-literals\npackage sample\n")
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expect_value(t, len(parser.errors), 0) { return }
	scopes: Scope_Store
	if !testing.expect_value(t, scope_store_init(&scopes, context.allocator), nil) { return }
	defer scope_store_destroy(&scopes)
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	supplied := [?]string{"supplied"}
	file := File {
		source = source,
		ast = &ast,
		policy = {features = supplied[:], bounds_check = .Enabled},
	}
	root := syntax.node_payload(&ast, ast.root, syntax.File)
	if !testing.expect_value(t, collect_file_features(&collection, &file, root), nil) { return }
	if !testing.expect_value(t, len(file.policy.features), 3) { return }
	testing.expect_value(t, file.policy.features[0], "supplied")
	testing.expect_value(t, file.policy.features[1], "global-context")
	testing.expect_value(t, file.policy.features[2], "dynamic-literals")
	testing.expect_value(t, file.policy.bounds_check, Check_Policy.Enabled)
}
