package check

import "core:mem"
import "core:testing"

@(test)
scope_bindings_follow_lexical_boundaries :: proc(t: ^testing.T) {
	store: Scope_Store
	init_err := scope_store_init(&store, context.allocator)
	testing.expect_value(t, init_err, nil)
	defer scope_store_destroy(&store)
	universal := test_scope(t, &store, 0, .Universal)
	package_scope := test_scope(t, &store, universal, .Package)
	file := test_scope(t, &store, package_scope, .File)
	outer := test_scope(t, &store, file, .Procedure)
	body := test_scope(t, &store, outer, .Block)
	inner := test_scope(t, &store, body, .Procedure)
	inner_body := test_scope(t, &store, inner, .Block)
	deeper := test_scope(t, &store, body, .Block)
	global := test_declare(t, &store, Entity{name = "hidden", scope = file, kind = .Variable, data = Variable_Data{storage = .Global}})
	local := test_declare(t, &store, Entity{name = "hidden", scope = body, kind = .Variable, data = Variable_Data{storage = .Local}})
	constant := test_declare(t, &store, Entity{name = "K", scope = body, kind = .Constant})
	result := test_declare(t, &store, Entity{name = "result", scope = outer, kind = .Variable, flags = {.Result}})
	parameter := test_declare(t, &store, Entity{name = "argument", scope = outer, kind = .Variable, flags = {.Parameter}})
	label := test_declare(t, &store, Entity{name = "loop", scope = body, kind = .Label})
	static := test_declare(t, &store, Entity{name = "static", scope = body, kind = .Variable, data = Variable_Data{storage = .Global}})
	tls := test_declare(t, &store, Entity{name = "tls", scope = body, kind = .Variable, data = Variable_Data{storage = .Thread_Local}})
	imported := test_declare(t, &store, Entity{name = "pkg", scope = file, kind = .Import_Name, data = Import_Data{package_id = 1}})
	builtin := test_declare(t, &store, Entity{name = "builtin", scope = universal, kind = .Builtin})
	lookups := []struct {
		scope:         Scope_Id,
		name:          string,
		entity:        Entity_Id,
		binding_scope: Scope_Id,
	} {
		{body, "hidden", local, body},
		{inner_body, "hidden", global, file},
		{body, "argument", parameter, outer},
		{inner_body, "argument", 0, 0},
		{body, "loop", label, body},
		{inner_body, "loop", 0, 0},
		{inner_body, "K", constant, body},
		{inner_body, "static", static, body},
		{inner_body, "tls", tls, body},
		{inner_body, "pkg", imported, file},
		{inner_body, "builtin", builtin, universal},
	}
	for expected in lookups {
		entity, found_scope := scope_lookup(&store, expected.scope, expected.name)
		testing.expect_value(t, entity, expected.entity)
		testing.expect_value(t, found_scope, expected.binding_scope)
	}
	duplicate, err := entity_create(&store, Entity{name = "hidden", scope = body, kind = .Constant})
	testing.expect_value(t, err, nil)
	previous, bind_err := scope_insert(&store, body, duplicate)
	testing.expect(t, bind_err == nil && previous == local)
	testing.expect_value(t, scope_lookup_current(&store, body, "hidden"), local)
	previous, bind_err = scope_insert(&store, body, local)
	testing.expect(t, bind_err == nil && previous == 0)
	shadow, create_err := entity_create(&store, Entity{name = "result", scope = body, kind = .Variable})
	testing.expect_value(t, create_err, nil)
	previous, bind_err = scope_insert(&store, body, shadow)
	testing.expect(t, bind_err == nil && previous == result)
	testing.expect_value(t, scope_lookup_current(&store, body, "result"), Entity_Id(0))
	_ = test_declare(t, &store, Entity{name = "result", scope = deeper, kind = .Variable})
	inner_declarations := len(scope_get(&store, inner_body).declarations)
	previous, bind_err = scope_insert_with_name(&store, inner_body, "alias", constant)
	testing.expect(t, bind_err == nil && previous == 0)
	testing.expect_value(t, scope_lookup_current(&store, inner_body, "alias"), constant)
	testing.expect_value(t, entity_get(&store, constant).scope, body)
	testing.expect_value(t, len(scope_get(&store, inner_body).declarations), inner_declarations)
	for _ in 0 ..< 2 { _ = test_declare(t, &store, Entity{name = "_", scope = body, kind = .Variable}) }
	testing.expect_value(t, scope_lookup_current(&store, body, "_"), Entity_Id(0))

	starved := test_scope(t, &store, body, .Block)
	store.scope_declarations[starved].allocator = mem.nil_allocator()
	entity_count := len(store.entities)
	failed, failed_err := entity_create(&store, Entity{name = "later", scope = starved, kind = .Constant})
	testing.expect(t, failed_err != nil && failed == 0)
	testing.expect_value(t, len(store.entities), entity_count)
	testing.expect_value(t, len(scope_get(&store, starved).declarations), 0)
	store.scope_declarations[starved].allocator = context.allocator
	staged, staged_err := entity_create(&store, Entity{name = "later", scope = starved, kind = .Constant})
	testing.expect(t, staged_err == nil && staged == Entity_Id(entity_count))
	testing.expect_value(t, scope_lookup_current(&store, starved, "later"), Entity_Id(0))
	scope_get(&store, starved).lookup.allocator = mem.nil_allocator()
	previous, bind_err = scope_insert(&store, starved, staged)
	testing.expect(t, bind_err != nil && previous == 0)
	testing.expect_value(t, scope_lookup_current(&store, starved, "later"), Entity_Id(0))
	scope_get(&store, starved).lookup.allocator = context.allocator
	previous, bind_err = scope_insert(&store, starved, staged)
	testing.expect(t, bind_err == nil && previous == 0)
	for i in 0 ..< 128 {
		id, growth_err := entity_create(&store, Entity{scope = body, order = {offset = u32(i)}})
		testing.expect(t, growth_err == nil && id == Entity_Id(entity_count + 1 + i))
		_ = test_scope(t, &store, body, .Block)
	}
	testing.expect_value(t, scope_lookup_current(&store, body, "hidden"), local)
	declarations := scope_get(&store, body).declarations
	testing.expect_value(t, declarations[0], local)
	for id in declarations { testing.expect_value(t, entity_get(&store, id).scope, body) }

	_, invalid_err := scope_create(&store, Scope_Id(max(u32)), .Block)
	testing.expect_value(t, invalid_err, Binding_Error(Scope_Error.Invalid_Scope))
	testing.expect(t, entity_get(&store, 0) == nil && scope_get(&store, 0) == nil)
	zero: Scope_Store
	_, zero_err := scope_create(&zero, 0, .Universal)
	testing.expect_value(t, zero_err, Binding_Error(Scope_Error.Uninitialized))
	testing.expect(t, scope_store_init(&zero, mem.nil_allocator()) != nil)
	testing.expect(t, len(zero.entities) == 0 && len(zero.scopes) == 0 && zero.allocator.procedure == nil)
	scope_store_destroy(&zero)
	scope_store_destroy(&store)
	testing.expect(t, len(store.entities) == 0 && len(store.scopes) == 0 && len(store.scope_declarations) == 0)
}

@(private = "file")
test_scope :: proc(t: ^testing.T, store: ^Scope_Store, parent: Scope_Id, kind: Scope_Kind) -> Scope_Id {
	id, err := scope_create(store, parent, kind)
	testing.expect_value(t, err, nil)
	return id
}

@(private = "file")
test_declare :: proc(t: ^testing.T, store: ^Scope_Store, descriptor: Entity) -> Entity_Id {
	id, err := entity_create(store, descriptor)
	testing.expect_value(t, err, nil)
	previous, bind_err := scope_insert(store, descriptor.scope, id)
	testing.expect(t, bind_err == nil && previous == 0)
	return id
}
