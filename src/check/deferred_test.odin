package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// Fixture for deferred-attribute tests. check_procedure_source covers the
// single-diagnostic cases; this fixture exposes entities and plans so the
// recorded markers, the published procedures and the backfilled call plans
// can be asserted directly.
Deferred_Fixture :: struct {
	ast:          syntax.Ast,
	parser:       syntax.Parser,
	store:        types.Store,
	pool:         Constant_Pool,
	scopes:       Scope_Store,
	file:         File,
	collection:   Collection,
	checker:      Expression_Checker,
	resolver:     Resolver,
	type_checker: Type_Checker,
	packages:     [2]Package,
	files:        [2]^File,
}

@(private = "file")
deferred_fixture_destroy :: proc(fixture: ^Deferred_Fixture) {
	expression_checker_destroy(&fixture.checker)
	type_checker_destroy(&fixture.type_checker)
	resolver_destroy(&fixture.resolver)
	collection_destroy(&fixture.collection)
	scope_store_destroy(&fixture.scopes)
	constant_pool_destroy(&fixture.pool)
	types.destroy(&fixture.store)
	syntax.parser_destroy(&fixture.parser)
	syntax.ast_destroy(&fixture.ast)
}

@(private = "file")
deferred_fixture_collect :: proc(t: ^testing.T, source: string) -> (^Deferred_Fixture, bool) {
	fixture := new(Deferred_Fixture, context.allocator)
	bytes := transmute([]byte)source
	syntax.ast_init(&fixture.ast, context.allocator)
	syntax.parser_init(&fixture.parser, &fixture.ast, bytes, context.allocator)
	syntax.parse_file(&fixture.parser)
	if !testing.expectf(t, len(fixture.parser.errors) == 0 && len(fixture.parser.lex_errors) == 0, "%v", fixture.parser.errors) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	fixture.store = types.init()
	integer := types.intern(&fixture.store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&fixture.store, types.Type{kind = .Bool})
	word := types.intern(&fixture.store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	if !testing.expect(t, constant_pool_init(&fixture.pool, context.allocator) == nil) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	if !testing.expect(t, scope_store_init(&fixture.scopes, context.allocator) == nil) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	universe, universe_error := scope_create(&fixture.scopes, 0, .Universal)
	package_scope, package_error := scope_create(&fixture.scopes, universe, .Package)
	file_scope, file_error := scope_create(&fixture.scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && file_error == nil) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	for value in ([2]bool{false, true}) {
		constant, constant_error := constant_pool_intern_bool(&fixture.pool, value, types.TYPE_UNTYPED_BOOL)
		if !testing.expect(t, constant_error == nil) {
			deferred_fixture_destroy(fixture)
			free(fixture, context.allocator)
			return nil, false
		}
		name := "true" if value else "false"
		entity, create_error := entity_create(
			&fixture.scopes,
			Entity{name = name, kind = .Constant, scope = universe, state = .Resolved, type = types.TYPE_UNTYPED_BOOL, constant = constant},
		)
		_, insert_error := scope_insert(&fixture.scopes, universe, entity)
		if !testing.expect(t, create_error == nil && insert_error == nil) {
			deferred_fixture_destroy(fixture)
			free(fixture, context.allocator)
			return nil, false
		}
	}
	if !testing.expect(t, bind_builtin_types(&fixture.scopes, universe, seed_builtin_types(&fixture.store)) == nil) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	builtin_error := bind_universe_builtins(&fixture.scopes, universe)
	if !testing.expect(t, builtin_error == nil) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	fixture.file = File {
		package_id = 1,
		ast        = &fixture.ast,
		source     = bytes,
		scope      = file_scope,
	}
	collection_init(&fixture.collection, &fixture.scopes, context.allocator)
	if !testing.expect(t, collect_file(&fixture.collection, &fixture.file, 1, {}) == nil) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	resolver_init(&fixture.resolver, &fixture.scopes, expression_declaration, &fixture.checker, context.allocator)
	fixture.files = [2]^File{nil, &fixture.file}
	type_checker_init(
		&fixture.type_checker,
		&fixture.resolver,
		&fixture.collection,
		&fixture.store,
		fixture.files[:],
		expression_integer_evaluator,
		&fixture.checker,
		context.allocator,
	)
	if !testing.expect(
		t,
		expression_checker_init(
			&fixture.checker,
			&fixture.type_checker,
			&fixture.pool,
			{uintptr = word, layout = types.DEFAULT_LAYOUT},
			integer,
			boolean,
			context.allocator,
		) ==
		nil,
	) {
		deferred_fixture_destroy(fixture)
		free(fixture, context.allocator)
		return nil, false
	}
	fixture.packages = [2]Package{{}, {kind = .User, name = "sample", scope = package_scope}}
	fixture.checker.packages = fixture.packages[:]
	return fixture, true
}

@(private = "file")
deferred_fixture_resolve :: proc(t: ^testing.T, fixture: ^Deferred_Fixture) -> bool {
	if deferred_debug_skip_resolve { return true }
	for declaration in fixture.collection.declarations {
		_, err := resolve_entity(&fixture.resolver, declaration.entity)
		if !testing.expect_value(t, err, nil) { return false }
	}
	return true
}

// Set while bisecting a crash. Never true in committed code.
deferred_debug_skip_resolve := false

@(private = "file")
deferred_entity :: proc(t: ^testing.T, fixture: ^Deferred_Fixture, name: string) -> Entity_Id {
	package_scope := scope_get(&fixture.scopes, fixture.file.scope).parent
	id := scope_lookup_current(&fixture.scopes, package_scope, name)
	if !testing.expect(t, id != 0) { return 0 }
	return id
}

@(test)
deferred_out_records_and_publishes :: proc(t: ^testing.T) {
	fixture, ok := deferred_fixture_collect(
		t,
		`package sample
close :: proc(a: int, b: int) {}
@(deferred_out = close)
guarded :: proc() -> (int, int) { return 1, 2 }
take :: proc(v: int) {}
@(deferred_in = take)
produce :: proc(v: int) -> int { return v }
noop :: proc() {}
@(deferred_out = noop)
quiet :: proc() {}
@(deferred_none = noop)
silent :: proc(x: int) -> int { return x }
main :: proc() {
	x, y := guarded()
	z := produce(x + y)
	_ = z
	quiet()
	w := silent(z)
	_ = w
}
`,
	)
	if !ok { return }
	defer deferred_fixture_destroy(fixture)
	defer free(fixture, context.allocator)
	if !testing.expect(t, len(fixture.collection.diagnostics) == 0) { return }
	if !deferred_fixture_resolve(t, fixture) { return }
	if !testing.expect(t, len(fixture.checker.diagnostics) == 0) { return }
	guarded := deferred_entity(t, fixture, "guarded")
	close := deferred_entity(t, fixture, "close")
	if guarded == 0 || close == 0 { return }
	marker := procedure_deferred_target(&fixture.scopes, guarded)
	testing.expect(t, marker == close)
	produce := deferred_entity(t, fixture, "produce")
	take := deferred_entity(t, fixture, "take")
	if produce == 0 || take == 0 { return }
	testing.expect(t, procedure_deferred_target(&fixture.scopes, produce) == take)
	program: Checked_Program
	if !testing.expect(t, expression_checker_publish_procedures(&fixture.checker, &program) == nil) { return }
	found_guarded, found_call := false, false
	for procedure in program.procedure_list {
		if procedure.entity != guarded { continue }
		found_guarded = true
		if !testing.expect(t, len(procedure.attributes) == 1) { return }
		if len(procedure.attributes) == 1 {
			testing.expect(t, procedure.attributes[0].name == "deferred_out" && procedure.attributes[0].entity == close)
		}
	}
	testing.expect(t, found_guarded)
	for plan in program.plan_table {
		call, is_call := plan.(Call_Plan)
		if is_call && call.entity == guarded {
			found_call = true
			testing.expect(t, call.deferred == close)
		}
	}
	testing.expect(t, found_call)
}

@(test)
deferred_out_rejects_mismatch :: proc(t: ^testing.T) {
	_, ok := check_procedure_source(
		t,
		transmute([]byte)string(`package sample
close :: proc(a: int) {}
@(deferred_out = close)
use0 :: proc() -> (int, int) { return 1, 2 }
`),
		.Unsupported,
		"Deferred procedure 'close' parameters do not match the results of initial procedure 'use0': (int) =/= (int, int)",
		1,
		"use0",
	)
	testing.expect(t, ok)
}

@(test)
deferred_out_rejects_self_and_chaining :: proc(t: ^testing.T) {
	fixture, ok := deferred_fixture_collect(
		t,
		`package sample
@(deferred_out = loop)
loop :: proc() {}
last :: proc() {}
@(deferred_out = last)
mid :: proc() {}
@(deferred_out = mid)
first :: proc() {}
`,
	)
	if !ok { return }
	defer deferred_fixture_destroy(fixture)
	defer free(fixture, context.allocator)
	if !deferred_fixture_resolve(t, fixture) { return }
	if !testing.expect(t, len(fixture.checker.diagnostics) == 2) { return }
	testing.expect(
		t,
		fixture.checker.diagnostics[0].reason == "'loop' cannot be used as its own deferred_out" &&
		fixture.checker.diagnostics[1].reason ==
			"Deferred procedure 'mid' cannot be used as the target of 'first' because it has a deferred procedure itself (deferred procedure chaining is not allowed)",
	)
}

@(test)
deferred_tail_after_diverging_call_is_unreachable :: proc(t: ^testing.T) {
	_, ok := check_procedure_source(
		t,
		transmute([]byte)string(
			`package sample
close :: proc(v: int) {}
@(deferred_out = close)
guarded :: proc() -> int { return 1 }
trap :: proc() -> ! { for {} }
main :: proc() {
	x := guarded()
	_ = x
	trap()
}
`,
		),
		.Unsupported,
		"Unreachable deferred procedure call due to a diverging procedure call at the end of the current scope",
		1,
		"main",
	)
	testing.expect(t, ok)
}

@(test)
deferred_unknown_attributes_are_rejected :: proc(t: ^testing.T) {
	fixture, ok := deferred_fixture_collect(t, `package sample
@(frobnicate) answer :: 42
`)
	if !ok { return }
	defer deferred_fixture_destroy(fixture)
	defer free(fixture, context.allocator)
	if !testing.expect(t, len(fixture.collection.diagnostics) == 1) { return }
	testing.expect(t, fixture.collection.diagnostics[0].kind == .Unknown_Attribute)
	procedure_fixture, procedure_ok := deferred_fixture_collect(t, `package sample
@(frobnicate) p :: proc() {}
`)
	if !procedure_ok { return }
	defer deferred_fixture_destroy(procedure_fixture)
	defer free(procedure_fixture, context.allocator)
	if !testing.expect(t, len(procedure_fixture.collection.diagnostics) == 0) { return }
	if !deferred_fixture_resolve(t, procedure_fixture) { return }
	if !testing.expect(t, len(procedure_fixture.checker.diagnostics) == 1) { return }
	diagnostic := procedure_fixture.checker.diagnostics[0]
	testing.expect(t, diagnostic.kind == .Unsupported && diagnostic.reason == "Unknown attribute element name 'frobnicate'")
}

@(test)
deferred_out_on_local_procedure_resolves_forward :: proc(t: ^testing.T) {
	fixture, ok := deferred_fixture_collect(
		t,
		`package sample
main :: proc() {
	@(deferred_out = close)
	open :: proc(s: string) -> bool { return true }
	close :: proc(ok: bool) {}
	ok := open("hi")
	close(ok)
}
`,
	)
	if !ok { return }
	defer deferred_fixture_destroy(fixture)
	defer free(fixture, context.allocator)
	if !deferred_fixture_resolve(t, fixture) { return }
	if !testing.expect(t, len(fixture.checker.diagnostics) == 0) { return }
	main := deferred_entity(t, fixture, "main")
	if main == 0 { return }
	main_data := entity_get(&fixture.scopes, main).data.(Procedure_Data)
	testing.expect(t, main_data.body_state == .Complete)
}
