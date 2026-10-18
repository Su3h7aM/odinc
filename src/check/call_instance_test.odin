package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "file")
check_last_procedure_source :: proc(t: ^testing.T, source: []byte) -> (procedure: Procedure_Data, ok: bool) {
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%v", parser.errors) { return {}, false }
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return {}, false }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return {}, false }
	defer scope_store_destroy(&scopes)
	universe, universe_error := scope_create(&scopes, 0, .Universal)
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && file_error == nil) { return {}, false }
	byte_id, byte_create_error := entity_create(&scopes, Entity{name = "u8", kind = .Type_Name, scope = universe, state = .Resolved, type = byte_type})
	_, byte_insert_error := scope_insert(&scopes, universe, byte_id)
	if !testing.expect(t, byte_create_error == nil && byte_insert_error == nil) { return {}, false }
	runtime_scope, runtime_scope_error := scope_create(&scopes, universe, .Package)
	if !testing.expect(t, runtime_scope_error == nil) { return {}, false }
	context_type := types.intern(&store, types.Type{kind = .Struct, name = "Context", fields = []types.Type_Field{{name = "allocator", type = integer}}})
	context_id, context_create_error := entity_create(
		&scopes,
		Entity{name = "Context", kind = .Type_Name, scope = runtime_scope, state = .Resolved, type = context_type},
	)
	_, context_insert_error := scope_insert(&scopes, runtime_scope, context_id)
	if !testing.expect(t, context_create_error == nil && context_insert_error == nil) { return {}, false }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	collection.runtime_scope = runtime_scope
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return {}, false }
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
	) { return {}, false }
	defer expression_checker_destroy(&checker)
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		if !testing.expectf(t, err == nil && state == .Resolved, "%v %v", state, err) { return {}, false }
	}
	return entity_get(&scopes, collection.declarations[len(collection.declarations) - 1].entity).data.(Procedure_Data), true
}

@(test)
context_field_reads_and_rebinds_within_procedure :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc() {
	allocator := context.allocator
	_ = allocator
	context.allocator = 3
	ctx := context
	context = ctx
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
generic_call_instantiates_and_checks_caller_body :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
id :: proc "contextless" (x: $T) -> T {
	return x
}
main :: proc "contextless" () {
	value := id(3)
	_ = value
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
typeid_parameter_binds_type_without_runtime_argument :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
pick :: proc "contextless" ($T: typeid, x: T) -> T {
	return x
}
main :: proc "contextless" () {
	value := pick(u8, 4)
	_ = value
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
constant_parameter_binds_value_in_instance_body :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
scale :: proc "contextless" ($N: int, x: int) -> [N]int {
	result: [N]int
	return result
}
main :: proc "contextless" () {
	value := scale(3, 4)
	_ = value
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
pattern_parameters_bind_from_argument_shape :: proc(t: ^testing.T) {

	@(test)
	implicit_selector_argument_takes_default_parameter_type :: proc(t: ^testing.T) {
		source := transmute([]byte)string(
			`package sample
Mode :: enum {
	A,
	B,
}
pick :: proc "contextless" (x: $T, mode := Mode.A) -> int {
	return int(mode)
}
main :: proc "contextless" () {
	value := pick(1, .B)
	_ = value
}
`,
		)
		procedure, ok := check_last_procedure_source(t, source)
		if !ok { return }
		testing.expect(t, procedure.body_state == .Complete)
	}
	source := transmute([]byte)string(
		`package sample
deref :: proc "contextless" (p: ^$T) -> T {
	return p^
}
first :: proc "contextless" (xs: []$T) -> T {
	return xs[0]
}
sum :: proc "contextless" (a: [$N]$T) -> T {
	total: T
	for i in 0 ..< N {
		total += a[i]
	}
	return total
}
copy_into :: proc "contextless" (dst, src: $T/[]$E) -> int {
	return len(dst) + len(src)
}
main :: proc "contextless" () {
	x := 5
	values := [2]int{1, 2}
	a := deref(&x)
	b := first(values[:])
	c := sum(values)
	d := copy_into(values[:], values[:])
	_, _, _, _ = a, b, c, d
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}
