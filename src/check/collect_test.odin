package check

import "core:strings"
import "core:testing"
import "oc:syntax"

@(test)
collection_preserves_visibility_and_delayed_declarations :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
import fmt "core:fmt"
foreign import library "system:library.so"
@(export) foreign import visible_library "system:visible.so"
when Enabled {
	Chosen :: 1
} else {
	Unchosen :: 2
}
Enabled :: true
Answer :: 42
Global: int
Pair, Other: int = 1, 2
Record :: struct { value: int }
Alias :: Record
function :: proc() {}
overload :: proc{function}
@(private) shared :: 1
@(private = "f\u0069le") hidden :: 2
@(export) exported :: proc() {}
foreign library {
	external :: proc() ---
}
foreign library {
	when Enabled {
		late_external :: proc() ---
	}
	early_external :: proc() ---
}
Conflict :: 1
Conflict :: 2
_ :: 3
`,
	)
	other_source := transmute([]byte)string("#+private file\npackage sample\n@(private = `package`) hidden :: 90\n@(test) local_test :: proc() {}\n")
	ast, other_ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	syntax.ast_init(&other_ast, context.allocator)
	defer syntax.ast_destroy(&other_ast)
	parser, other_parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parser_init(&other_parser, &other_ast, other_source, context.allocator)
	defer syntax.parser_destroy(&other_parser)
	syntax.parse_file(&parser)
	syntax.parse_file(&other_parser)
	if !testing.expect(
		t,
		len(parser.errors) == 0 && len(parser.lex_errors) == 0 && len(other_parser.errors) == 0 && len(other_parser.lex_errors) == 0,
	) { return }

	store: Scope_Store
	if !testing.expect(t, scope_store_init(&store, context.allocator) == nil) { return }
	defer scope_store_destroy(&store)
	package_scope, package_err := scope_create(&store, 0, .Package)
	file_scope, file_err := scope_create(&store, package_scope, .File)
	other_scope, other_err := scope_create(&store, package_scope, .File)
	if !testing.expect(t, package_err == nil && file_err == nil && other_err == nil) { return }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	other_file := File {
		package_id = 1,
		ast        = &other_ast,
		source     = other_source,
		scope      = other_scope,
	}
	collection: Collection
	collection_init(&collection, &store, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil) { return }
	if !testing.expect(t, collect_file(&collection, &other_file, 2, {file_order = 1}) == nil) { return }

	expected_entities := []struct {
		name: string,
		kind: Entity_Kind,
	} {
		{"Answer", .Constant},
		{"Global", .Variable},
		{"Pair", .Variable},
		{"Other", .Variable},
		{"Record", .Type_Name},
		{"Alias", .Constant},
		{"function", .Procedure},
		{"overload", .Procedure_Group},
		{"external", .Procedure},
		{"visible_library", .Library_Name},
	}
	for expected in expected_entities {
		entity := entity_get(&store, scope_lookup_current(&store, package_scope, expected.name))
		if !testing.expect(t, entity != nil) { continue }
		testing.expect(t, entity.kind == expected.kind && entity.scope == file_scope && entity.state == .Unresolved)
	}
	testing.expect(t, entity_get(&store, scope_lookup_current(&store, package_scope, "Global")).data.(Variable_Data).storage == .Global)
	testing.expect(t, .Foreign in entity_get(&store, scope_lookup_current(&store, package_scope, "external")).flags)
	testing.expect(t, .Export in entity_get(&store, scope_lookup_current(&store, package_scope, "exported")).flags)
	testing.expect(t, .Private_Package in entity_get(&store, scope_lookup_current(&store, package_scope, "shared")).flags)
	local_hidden := scope_lookup_current(&store, file_scope, "hidden")
	package_hidden := scope_lookup_current(&store, package_scope, "hidden")
	testing.expect(t, local_hidden != 0 && package_hidden != 0 && local_hidden != package_hidden)
	testing.expect(t, .Private_File in entity_get(&store, local_hidden).flags)
	testing.expect(t, .Private_Package in entity_get(&store, package_hidden).flags)
	testing.expect(t, scope_lookup_current(&store, other_scope, "local_test") != 0 && scope_lookup_current(&store, package_scope, "local_test") == 0)
	testing.expect(t, scope_lookup_current(&store, file_scope, "library") != 0 && scope_lookup_current(&store, package_scope, "library") == 0)
	testing.expect(t, scope_lookup_current(&store, file_scope, "fmt") == 0)
	testing.expect(t, scope_lookup_current(&store, package_scope, "Chosen") == 0 && scope_lookup_current(&store, package_scope, "Unchosen") == 0)
	testing.expect(t, scope_lookup_current(&store, package_scope, "early_external") == 0)
	testing.expect(t, scope_lookup_current(&store, package_scope, "_") == 0)
	if testing.expect(t, len(collection.diagnostics) == 1) {
		diagnostic := collection.diagnostics[0]
		first := u32(strings.index(string(source), "Conflict :: 1"))
		second := u32(strings.index(string(source), "Conflict :: 2"))
		testing.expect(t, diagnostic.kind == .Redeclaration && diagnostic.name == "Conflict")
		testing.expect(t, diagnostic.source == Source_Span{1, second, second + 8} && diagnostic.related == Source_Span{1, first, first + 8})
		testing.expect(t, entity_get(&store, scope_lookup_current(&store, package_scope, "Conflict")).order.offset == first)
	}
	when_index, foreign_index := -1, -1
	for pending, index in collection.pending {
		if pending.kind == .When { when_index = index }
		if pending.kind == .Foreign_Block { foreign_index = index }
	}
	if !testing.expect(t, when_index >= 0 && foreign_index >= 0) { return }
	testing.expect(t, collect_when_arm(&collection, &file, when_index, true) == nil)
	testing.expect(t, scope_lookup_current(&store, package_scope, "Chosen") != 0 && scope_lookup_current(&store, package_scope, "Unchosen") == 0)
	testing.expect(t, collect_foreign_block(&collection, &file, foreign_index, .Public) == nil)
	testing.expect(t, scope_lookup_current(&store, package_scope, "early_external") != 0 && scope_lookup_current(&store, package_scope, "late_external") == 0)
	testing.expect(t, collect_when_arm(&collection, &file, len(collection.pending) - 1, true) == nil)
	late := scope_lookup_current(&store, package_scope, "late_external")
	testing.expect(t, late != 0 && .Foreign in entity_get(&store, late).flags)
	testing.expect(t, collect_import_name(&collection, &file, 0, "resolved_name", 77) == nil)
	imported := entity_get(&store, scope_lookup_current(&store, file_scope, "fmt"))
	testing.expect(t, imported != nil && imported.kind == .Import_Name && imported.data.(Import_Data).package_id == 77)
	testing.expect(t, scope_lookup_current(&store, package_scope, "fmt") == 0 && len(collection.diagnostics) == 1)
	for declaration in collection.declarations {
		if declaration.entity == late { testing.expect(t, declaration.foreign_block.node != 0 && declaration.value.node != 0) }
	}
}
