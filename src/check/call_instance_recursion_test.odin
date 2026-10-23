package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// A recursive generic call finds its own instance still resolving. The signature is assigned before the
// body is checked, so the call checks against the known signature and keeps a plan, like upstream's reuse
// of an in-progress specialization. These tests assert the checked rows directly: before the fix the inner
// call was silent poison (no diagnostic, body still Complete), which lowering reported as Unchecked_Expression.
@(private = "file")
Recursive_Fixture :: struct {
	ast:           syntax.Ast,
	parser:        syntax.Parser,
	store:         types.Store,
	pool:          Constant_Pool,
	scopes:        Scope_Store,
	collection:    Collection,
	resolver:      Resolver,
	type_checker:  Type_Checker,
	checker:       Expression_Checker,
	file:          File,
	package_scope: Scope_Id,
	files:         [2]^File,
}

recursive_check :: proc(t: ^testing.T, source: []byte, fixture: ^Recursive_Fixture) -> bool {
	syntax.ast_init(&fixture.ast, context.allocator)
	syntax.parser_init(&fixture.parser, &fixture.ast, source, context.allocator)
	syntax.parse_file(&fixture.parser)
	if !testing.expectf(t, len(fixture.parser.errors) == 0 && len(fixture.parser.lex_errors) == 0, "%v", fixture.parser.errors) {
		return false
	}
	fixture.store = types.init()
	integer := types.intern(&fixture.store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&fixture.store, types.Type{kind = .Bool})
	word := types.intern(&fixture.store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	if !testing.expect(t, constant_pool_init(&fixture.pool, context.allocator) == nil) { return false }
	if !testing.expect(t, scope_store_init(&fixture.scopes, context.allocator) == nil) { return false }
	universe, universe_error := scope_create(&fixture.scopes, 0, .Universal)
	package_scope, package_error := scope_create(&fixture.scopes, universe, .Package)
	file_scope, file_error := scope_create(&fixture.scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && file_error == nil) { return false }
	fixture.package_scope = package_scope
	for value in ([2]bool{false, true}) {
		constant, constant_error := constant_pool_intern_bool(&fixture.pool, value, types.TYPE_UNTYPED_BOOL)
		if !testing.expect(t, constant_error == nil) { return false }
		name := "true" if value else "false"
		entity, create_error := entity_create(
			&fixture.scopes,
			Entity{name = name, kind = .Constant, scope = universe, state = .Resolved, type = types.TYPE_UNTYPED_BOOL, constant = constant},
		)
		_, insert_error := scope_insert(&fixture.scopes, universe, entity)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return false }
	}
	if !testing.expect(t, bind_builtin_types(&fixture.scopes, universe, seed_builtin_types(&fixture.store)) == nil) { return false }
	if !testing.expect(t, bind_universe_builtins(&fixture.scopes, universe) == nil) { return false }
	fixture.file = File {
		package_id = 1,
		ast        = &fixture.ast,
		source     = source,
		scope      = file_scope,
	}
	collection_init(&fixture.collection, &fixture.scopes, context.allocator)
	if !testing.expect(t, collect_file(&fixture.collection, &fixture.file, 1, {}) == nil && len(fixture.collection.diagnostics) == 0) {
		return false
	}
	resolver_init(&fixture.resolver, &fixture.scopes, expression_declaration, &fixture.checker, context.allocator)
	fixture.files = {nil, &fixture.file}
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
		return false
	}
	fixture.checker.packages = make([]Package, 2, context.allocator)
	fixture.checker.packages[1] = Package {
		kind  = .User,
		scope = package_scope,
	}
	for declaration in fixture.collection.declarations {
		if _, err := resolve_entity(&fixture.resolver, declaration.entity); !testing.expect(t, err == nil) { return false }
	}
	return true
}

@(private = "file")
recursive_destroy :: proc(fixture: ^Recursive_Fixture) {
	delete(fixture.checker.packages, context.allocator)
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

// Every call node must be Checked with a plan in some view, and never Invalid in any view.
@(private = "file")
recursive_calls_checked :: proc(t: ^testing.T, fixture: ^Recursive_Fixture) {
	program: Checked_Program
	expression_checker_publish(&fixture.checker, &program)
	program.files = []File{{}, fixture.file}
	calls := 0
	for node, index in fixture.ast.nodes {
		if node.kind != .Call_Expr {
			continue
		}
		seen := false
		for view in 1 ..< len(program.typed_views) {
			info, found := expression_info(&program, View_Id(view), syntax.Node_Index(index))
			if !found || info.state == .Unseen {
				continue
			}
			if !testing.expectf(t, info.state == .Checked, "call node %d in view %d is %v", index, view, info.state) {
				return
			}
			if info.state == .Checked {
				seen = true
				testing.expectf(t, info.plan != 0, "call node %d in view %d has no plan", index, view)
			}
		}
		if !testing.expectf(t, seen, "call node %d checked in no view", index) {
			return
		}
		calls += 1
	}
	testing.expectf(t, calls > 0, "expected call nodes, found none")
}

@(private = "file")
recursive_instance :: proc(t: ^testing.T, fixture: ^Recursive_Fixture, name: string) -> Entity_Id {
	definition := scope_lookup_current(&fixture.scopes, fixture.package_scope, name)
	if !testing.expectf(t, definition != 0, "no procedure named %q", name) {
		return 0
	}
	for entity, id in fixture.scopes.entities {
		procedure, is_procedure := entity.data.(Procedure_Data)
		if is_procedure && procedure.definition == definition {
			return Entity_Id(id)
		}
	}
	testing.expectf(t, false, "no instance of %q", name)
	return 0
}

@(private = "file")
recursive_instance_resolved :: proc(t: ^testing.T, fixture: ^Recursive_Fixture, name: string) {
	instance := recursive_instance(t, fixture, name)
	if instance == 0 {
		return
	}
	entity := entity_get(&fixture.scopes, instance)
	testing.expectf(t, entity.state == .Resolved, "%q instance state is %v", name, entity.state)
	testing.expectf(t, entity.data.(Procedure_Data).body_state == .Complete, "%q instance body is %v", name, entity.data.(Procedure_Data).body_state)
}

// Official Odin builds and runs this, printing 0.
@(test)
generic_direct_recursion_checks_against_known_signature :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
countdown :: proc "contextless" (n: $T) -> T {
	if n <= 0 {
		return n
	}
	return countdown(n - 1)
}
main :: proc "contextless" () {
	countdown(3)
}
`,
	)
	fixture: Recursive_Fixture
	defer recursive_destroy(&fixture)
	if !recursive_check(t, source, &fixture) {
		return
	}
	testing.expectf(t, len(fixture.checker.diagnostics) == 0, "diagnostics %v", fixture.checker.diagnostics)
	recursive_instance_resolved(t, &fixture, "countdown")
	recursive_calls_checked(t, &fixture)
	for view, view_index in fixture.checker.views {
		if view.instance == 0 { continue }
		testing.expect(t, view.first_node > 0 && len(view.nodes.types) < len(fixture.ast.nodes), "instance rows must exclude unrelated file declarations")
		for node, node_index in fixture.ast.nodes {
			if node.kind != .Basic_Lit { continue }
			index := syntax.Node_Index(node_index)
			if index >= view.first_node && int(index - view.first_node) < len(view.nodes.types) { continue }
			view_id := View_Id(view_index)
			mark := expression_speculation_begin(&fixture.checker)
			expression_store(&fixture.checker, view_id, index, Expression_Info{state = .Checked})
			testing.expect(t, expression_stored_info(&fixture.checker, view_id, index).state == .Checked, "external rows must be readable")
			expression_speculation_end(&fixture.checker, mark)
			testing.expect(t, expression_stored_info(&fixture.checker, view_id, index).state == .Unseen, "external rows must roll back with dense rows")
			break
		}
	}
}

// A two-instance cycle through two generics: put calls expand, expand calls put.
@(test)
generic_two_instance_cycle_checks :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
ping :: proc "contextless" (n: $T) -> T {
	if n <= 0 {
		return n
	}
	return pong(n - 1)
}
pong :: proc "contextless" (n: $T) -> T {
	if n <= 0 {
		return n
	}
	return ping(n - 1)
}
main :: proc "contextless" () {
	ping(3)
}
`,
	)
	fixture: Recursive_Fixture
	defer recursive_destroy(&fixture)
	if !recursive_check(t, source, &fixture) {
		return
	}
	testing.expectf(t, len(fixture.checker.diagnostics) == 0, "diagnostics %v", fixture.checker.diagnostics)
	recursive_instance_resolved(t, &fixture, "ping")
	recursive_instance_resolved(t, &fixture, "pong")
	recursive_calls_checked(t, &fixture)
}

// A three-instance cycle: each generic calls the next, the last calls the first.
@(test)
generic_three_instance_cycle_checks :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
first :: proc "contextless" (n: $T) -> T {
	if n <= 0 {
		return n
	}
	return second(n - 1) + 1
}
second :: proc "contextless" (n: $T) -> T {
	if n <= 0 {
		return n
	}
	return third(n - 1) + 1
}
third :: proc "contextless" (n: $T) -> T {
	if n <= 0 {
		return n
	}
	return first(n - 1) + 1
}
main :: proc "contextless" () {
	first(9)
}
`,
	)
	fixture: Recursive_Fixture
	defer recursive_destroy(&fixture)
	if !recursive_check(t, source, &fixture) {
		return
	}
	testing.expectf(t, len(fixture.checker.diagnostics) == 0, "diagnostics %v", fixture.checker.diagnostics)
	recursive_instance_resolved(t, &fixture, "first")
	recursive_instance_resolved(t, &fixture, "second")
	recursive_instance_resolved(t, &fixture, "third")
	recursive_calls_checked(t, &fixture)
}

// Official Odin rejects this: 'Cannot convert ... instantiated as bad($T=int)'.
@(test)
generic_invalid_instance_still_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
bad :: proc "contextless" (x: $T) -> T {
	return x + "s"
}
main :: proc "contextless" () {
	bad(1)
}
`)
	fixture: Recursive_Fixture
	defer recursive_destroy(&fixture)
	if !recursive_check(t, source, &fixture) {
		return
	}
	testing.expectf(t, len(fixture.checker.diagnostics) > 0, "invalid instance reported no diagnostic")
	instance := recursive_instance(t, &fixture, "bad")
	if instance == 0 {
		return
	}
	testing.expectf(
		t,
		entity_get(&fixture.scopes, instance).data.(Procedure_Data).body_state == .Invalid,
		"invalid instance body is %v",
		entity_get(&fixture.scopes, instance).data.(Procedure_Data).body_state,
	)
}

// Official Odin rejects this: ''where' clause evaluated to false ... at caller location'.
@(test)
generic_where_failure_still_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
countdown :: proc "contextless" (n: $T) -> T where size_of(T) == 1 {
	if n <= 0 {
		return n
	}
	return countdown(n - 1)
}
main :: proc "contextless" () {
	countdown(3)
}
`,
	)
	fixture: Recursive_Fixture
	defer recursive_destroy(&fixture)
	if !recursive_check(t, source, &fixture) {
		return
	}
	testing.expectf(t, len(fixture.checker.diagnostics) > 0, "where failure reported no diagnostic")
	instance := recursive_instance(t, &fixture, "countdown")
	if instance == 0 {
		return
	}
	testing.expectf(
		t,
		entity_get(&fixture.scopes, instance).state == .Invalid,
		"where-failed instance state is %v",
		entity_get(&fixture.scopes, instance).state,
	)
}
