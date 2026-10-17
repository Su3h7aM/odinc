package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
simd_types_layouts_and_intrinsic_results_check :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Bytes :: #simd[16]u8
Lanes :: #simd[4]f32
Odd :: #simd[3]u8
Text :: #simd[4]string
left: Bytes
right: Bytes
mask: Bytes
indices := simd_indices(Bytes)
lanes := simd_lanes_ne(left, right)
selected := simd_select(lanes, indices, mask)
low := simd_reduce_min(selected)
any_lane := simd_reduce_or(lanes)
float_lanes: Lanes
float_mask := simd_lanes_ne(float_lanes, float_lanes)
broadcast: Bytes = u8(0xFF)
bad := simd_lanes_ne(left, float_lanes)
`,
	)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%v", parser.errors) { return }

	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	float32 := types.intern(&store, types.Type{kind = .Float, count = 4})
	string_type := types.intern(&store, types.Type{kind = .String})
	unsigned32 := types.intern(&store, types.Type{kind = .Integer, count = 4})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, scope_error := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, scope_error == nil) { return }
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, package_error == nil && file_error == nil) { return }
	builtins := []struct {
		name: string,
		type: types.Type_Id,
	}{{"int", integer}, {"u8", byte_type}, {"f32", float32}, {"string", string_type}, {"uintptr", word}, {"bool", boolean}}
	for builtin in builtins {
		id, create_error := entity_create(&scopes, Entity{name = builtin.name, kind = .Type_Name, scope = universe, state = .Resolved, type = builtin.type})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return }
	}
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return }
	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	type_checker_init(&type_checker, &resolver, &collection, &store, []^File{nil, &file}, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)
	intrinsics := []struct {
		name: string,
		kind: Builtin_Kind,
	} {
		{"simd_indices", .Simd_Indices},
		{"simd_select", .Simd_Select},
		{"simd_lanes_ne", .Simd_Lanes_Ne},
		{"simd_reduce_min", .Simd_Reduce_Min},
		{"simd_reduce_or", .Simd_Reduce_Or},
	}
	for intrinsic in intrinsics {
		builtin, builtin_error := expression_builtin_id(&checker, intrinsic.kind)
		id, create_error := entity_create(&scopes, Entity{name = intrinsic.name, kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, builtin_error == nil && create_error == nil && insert_error == nil) { return }
	}
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		invalid := name == "Odd" || name == "Text" || name == "bad"
		testing.expectf(t, err == nil && (state == .Invalid) == invalid, "%s: %v %v", name, state, err)
	}
	count_reported, element_reported := false, false
	for diagnostic in type_checker.diagnostics {
		count_reported ||= diagnostic.kind == .Invalid_Simd_Count
		element_reported ||= diagnostic.kind == .Invalid_Simd_Element
	}
	testing.expect(t, len(type_checker.diagnostics) == 2 && count_reported && element_reported && len(resolver.diagnostics) == 0)

	lookup :: proc(scopes: ^Scope_Store, scope: Scope_Id, name: string) -> types.Type_Id {
		return entity_get(scopes, scope_lookup_current(scopes, scope, name)).type
	}
	bytes := lookup(&scopes, package_scope, "Bytes")
	bytes_descriptor := types.get(&store, bytes)^
	testing.expect(t, bytes_descriptor.kind == .Simd_Vector && bytes_descriptor.count == 16 && bytes_descriptor.elem == byte_type)
	size, alignment, layout_error := types.layout(&store, bytes)
	testing.expect(t, layout_error == .None && size == 16 && alignment == 16)
	lanes_size, lanes_alignment, _ := types.layout(&store, lookup(&scopes, package_scope, "Lanes"))
	testing.expect(t, lanes_size == 16 && lanes_alignment == 16)

	testing.expect(t, lookup(&scopes, package_scope, "indices") == bytes)
	testing.expect(t, lookup(&scopes, package_scope, "lanes") == bytes)
	testing.expect(t, lookup(&scopes, package_scope, "selected") == bytes)
	testing.expect(t, lookup(&scopes, package_scope, "broadcast") == bytes)
	testing.expect(t, lookup(&scopes, package_scope, "low") == byte_type)
	testing.expect(t, lookup(&scopes, package_scope, "any_lane") == byte_type)
	float_mask := types.get(&store, lookup(&scopes, package_scope, "float_mask"))^
	testing.expect(t, float_mask.kind == .Simd_Vector && float_mask.count == 4 && float_mask.elem == unsigned32)
}
