package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
record_instances_bind_parameters_and_preserve_nominal_identity :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Foo :: struct(T: typeid) { value: T }
Small_Array :: struct($N: int, $T: typeid) where N >= 0 && T == int { data: [N]T, len: int }
Other :: struct($N: int, $T: typeid) { data: [N]T, len: int }
Nested :: struct($T: typeid) { value: Foo(T), next: ^Nested(T) }
Choice :: union($T: typeid) { T, ^T }
Handle :: distinct Foo(int)
First :: Small_Array(3, int)
Same :: Small_Array(1 + 2, int)
Different :: Small_Array(4, int)
Separate :: Other(3, int)
Nested_Int :: Nested(int)
Nested_Byte :: Nested(u8)
Choice_Int :: Choice(int)
read :: proc "contextless" (value: ^Foo($T)) -> T { return value.value }
make_foo :: proc "contextless" (value: $T) -> Foo(T) { return Foo(T){value = value} }
count :: proc "contextless" (value: ^Small_Array($N, $T)) -> int { return N + value.len }
main :: proc "contextless" () {
	first: First
	same: Same = first
	foo := make_foo(7)
	value := read(&foo)
	length := count(&same)
	_ = length
	_ = same
	_ = value
}
Bad :: Small_Array(-1, int)
Wrong :: Small_Array(2, u8)
Bare :: Foo
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
	byte_type := types.intern(&store, types.Type{kind = .Integer, name = "u8", count = 1})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, universe_error := scope_create(&scopes, 0, .Universal)
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && file_error == nil) { return }
	for builtin in ([?]struct {
			name: string,
			type: types.Type_Id,
		}{{"int", integer}, {"u8", byte_type}}) {
		entity, create_error := entity_create(
			&scopes,
			Entity{name = builtin.name, kind = .Type_Name, scope = universe, state = .Resolved, type = builtin.type},
		)
		_, insert_error := scope_insert(&scopes, universe, entity)
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
	collection.runtime_scope = package_scope
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
	for declaration in collection.declarations {
		entity := entity_get(&scopes, declaration.entity)^
		state, err := resolve_entity(&resolver, declaration.entity)
		invalid := entity.name == "Bad" || entity.name == "Wrong" || entity.name == "Bare"
		if !testing.expectf(
			t,
			err == nil && (state == .Invalid) == invalid,
			"%s: %v %v; type %v; expression %v",
			entity.name,
			state,
			err,
			type_checker.diagnostics,
			checker.diagnostics,
		) { return }
	}
	lookup := proc(scopes: ^Scope_Store, scope: Scope_Id, name: string) -> types.Type_Id {
		return entity_get(scopes, scope_lookup_current(scopes, scope, name)).type
	}
	first := lookup(&scopes, package_scope, "First")
	testing.expect(t, first == lookup(&scopes, package_scope, "Same"))
	testing.expect(t, first != lookup(&scopes, package_scope, "Different"))
	testing.expect(t, first != lookup(&scopes, package_scope, "Separate"))
	descriptor := types.get(&store, first)^
	testing.expect(t, descriptor.name == "Small_Array($N=3, $T=int)")
	if testing.expect(t, len(descriptor.fields) == 2) {
		data := types.get(&store, descriptor.fields[0].type)^
		testing.expect(t, data.kind == .Array && data.count == 3 && data.elem == integer)
	}
	size, alignment, layout_error := types.layout(&store, first)
	testing.expect(t, size == 32 && alignment == 8 && layout_error == .None)
	for entry in ([?]struct {
			name: string,
			elem: types.Type_Id,
		}{{"Nested_Int", integer}, {"Nested_Byte", byte_type}}) {
		nested_type := lookup(&scopes, package_scope, entry.name)
		nested := types.get(&store, nested_type)^
		if testing.expect(t, len(nested.fields) == 2) {
			testing.expect(t, types.get(&store, nested.fields[1].type).elem == nested_type)
			foo := types.get(&store, nested.fields[0].type)^
			testing.expect(t, len(foo.fields) == 1 && foo.fields[0].type == entry.elem)
		}
	}
	choice := types.get(&store, lookup(&scopes, package_scope, "Choice_Int"))^
	testing.expect(t, choice.kind == .Union && len(choice.variants) == 2 && choice.variants[0] == integer)
	handle := types.get(&store, lookup(&scopes, package_scope, "Handle"))^
	testing.expect(t, handle.kind == .Named && handle.is_nominal)
	testing.expect(t, len(checker.diagnostics) == 0)
	testing.expect(t, len(type_checker.diagnostics) == 3)
	testing.expect(t, check_nominal_layouts(&type_checker) == nil)
}
