package check

import "base:runtime"
import "core:mem"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "file")
Resolver_Test_Data :: struct {
	collection:     ^Collection,
	file:           ^File,
	type_store:     ^types.Store,
	integer:        types.Type_Id,
	calls:          []int,
	identity_state: Resolution_State,
}

@(test)
foreign_library_is_used_only_by_reference :: proc(t: ^testing.T) {
	store: Scope_Store
	if !testing.expect_value(t, scope_store_init(&store, context.allocator), nil) { return }
	defer scope_store_destroy(&store)
	scope, scope_error := scope_create(&store, 0, .Package)
	if !testing.expect_value(t, scope_error, nil) { return }
	library, library_error := entity_create(&store, Entity{name = "lib", kind = .Library_Name, scope = scope, data = Library_Data{}})
	foreign_entity, foreign_error := entity_create(&store, Entity{name = "call", kind = .Procedure, scope = scope, flags = {.Foreign}, foreign_library = "lib"})
	owner, owner_error := entity_create(&store, Entity{name = "main", kind = .Procedure, scope = scope})
	if !testing.expect(t, library_error == nil && foreign_error == nil && owner_error == nil) { return }
	_, insert_error := scope_insert(&store, scope, library)
	if !testing.expect_value(t, insert_error, nil) { return }
	resolver: Resolver
	resolver_init(&resolver, &store, test_foreign_declaration, nil, context.allocator)
	defer resolver_destroy(&resolver)
	state, err := resolve_entity(&resolver, foreign_entity)
	testing.expect(t, state == .Resolved && err == nil && !entity_get(&store, library).data.(Library_Data).used)
	append(&resolver.stack, owner)
	state, err = resolve_dependency(&resolver, Dependency{entity = foreign_entity, kind = .Name})
	_ = pop(&resolver.stack)
	testing.expect(t, state == .Resolved && err == nil && entity_get(&store, library).data.(Library_Data).used)
}

@(private = "file")
test_foreign_declaration :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	return true, nil
}

@(test)
resolution_is_lazy_and_poisoned_cycles_do_not_repeat :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Root :: Leaf
Leaf :: 1
Dependent :: Cycle_A
Cycle_A :: Cycle_B
Cycle_B :: Cycle_C
Cycle_C :: Cycle_A
Self :: Self
Unused :: 0
Nominal :: struct {}
Grow :: 0
Bad :: 0
Fail :: 0
`,
	)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expect(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0) { return }
	store: Scope_Store
	if !testing.expect(t, scope_store_init(&store, context.allocator) == nil) { return }
	defer scope_store_destroy(&store)
	package_scope, package_err := scope_create(&store, 0, .Package)
	file_scope, file_err := scope_create(&store, package_scope, .File)
	if !testing.expect(t, package_err == nil && file_err == nil) { return }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &store, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return }
	type_store := types.init()
	defer types.destroy(&type_store)
	calls := make([]int, len(store.entities), context.allocator)
	defer delete(calls)
	data := Resolver_Test_Data {
		collection = &collection,
		file       = &file,
		type_store = &type_store,
		integer    = types.scalar(&type_store, .Integer, 8),
		calls      = calls,
	}
	resolver: Resolver
	resolver_init(&resolver, &store, test_resolve_declaration, &data, context.allocator)
	defer resolver_destroy(&resolver)
	root := scope_lookup_current(&store, package_scope, "Root")
	leaf := scope_lookup_current(&store, package_scope, "Leaf")
	unused := scope_lookup_current(&store, package_scope, "Unused")
	state, err := resolve_entity(&resolver, root)
	testing.expect(t, state == .Resolved && err == nil && len(resolver.stack) == 0)
	testing.expect(t, calls[root] == 1 && calls[leaf] == 1 && calls[unused] == 0 && entity_get(&store, unused).state == .Unresolved)
	dependencies := entity_get(&store, root).dependencies
	if testing.expect(t, len(dependencies) == 2) {
		testing.expect(
			t,
			dependencies[0].entity == leaf && dependencies[0].kind == .Constant && dependencies[1].entity == leaf && dependencies[1].kind == .Name,
		)
	}
	state, err = resolve_entity(&resolver, root)
	testing.expect(t, state == .Resolved && err == nil && calls[root] == 1)
	dependent := scope_lookup_current(&store, package_scope, "Dependent")
	state, err = resolve_entity(&resolver, dependent)
	testing.expect(t, state == .Invalid && err == nil && len(resolver.stack) == 0)
	cycle_names := []string{"Dependent", "Cycle_A", "Cycle_B", "Cycle_C"}
	for name in cycle_names {
		entity := entity_get(&store, scope_lookup_current(&store, package_scope, name))
		testing.expect(t, entity.state == .Invalid && entity.type == types.TYPE_POISON && entity.constant == 0)
	}
	expected_diagnostics := []struct {
		name: string,
		kind: Resolution_Diagnostic_Kind,
	}{{"Cycle_A", .Declaration_Cycle}, {"Cycle_A", .Refers_To}, {"Cycle_B", .Refers_To}, {"Cycle_C", .Refers_To}, {"Cycle_A", .Cycle_End}}
	if testing.expect(t, len(resolver.diagnostics) == len(expected_diagnostics)) {
		for expected, index in expected_diagnostics {
			diagnostic := resolver.diagnostics[index]
			entity := entity_get(&store, diagnostic.entity)
			testing.expect(
				t,
				diagnostic.name == expected.name &&
				diagnostic.kind == expected.kind &&
				diagnostic.source.file == 1 &&
				diagnostic.source.start == entity.order.offset,
			)
		}
	}
	state, err = resolve_entity(&resolver, dependent)
	testing.expect(t, state == .Invalid && err == nil && calls[dependent] == 1 && len(resolver.diagnostics) == 5)
	self := scope_lookup_current(&store, package_scope, "Self")
	state, err = resolve_entity(&resolver, self)
	testing.expect(t, state == .Invalid && err == nil && len(resolver.diagnostics) == 8 && len(entity_get(&store, self).dependencies) == 1)
	nominal := scope_lookup_current(&store, package_scope, "Nominal")
	state, err = resolve_entity(&resolver, nominal)
	testing.expect(t, state == .Resolved && err == nil && data.identity_state == .Resolving && len(resolver.diagnostics) == 8)
	grow := scope_lookup_current(&store, package_scope, "Grow")
	count := len(store.entities)
	state, err = resolve_entity(&resolver, grow)
	testing.expect(t, state == .Resolved && err == nil && len(store.entities) == count + 128 && entity_get(&store, grow).type == data.integer)
	bad := scope_lookup_current(&store, package_scope, "Bad")
	state, err = resolve_entity(&resolver, bad)
	testing.expect(t, state == .Invalid && err == nil && entity_get(&store, bad).type == types.TYPE_POISON && entity_get(&store, bad).constant == 0)
	fail := scope_lookup_current(&store, package_scope, "Fail")
	state, err = resolve_entity(&resolver, fail)
	allocation_error, allocation_failed := err.(runtime.Allocator_Error)
	testing.expect(
		t,
		state == .Invalid &&
		allocation_failed &&
		allocation_error == .Out_Of_Memory &&
		len(resolver.stack) == 0 &&
		entity_get(&store, fail).type == types.TYPE_POISON,
	)
	resolver.check_declaration = nil
	state, err = resolve_entity(&resolver, unused)
	callback_error, callback_missing := err.(Resolver_Failure)
	testing.expect(t, state == .Unresolved && callback_missing && callback_error == .No_Callback && entity_get(&store, unused).state == .Unresolved)
	state, err = resolve_entity(&resolver, 0)
	testing.expect(t, state == .Invalid && err != nil)
	resolver_destroy(&resolver)
	testing.expect(t, len(entity_get(&store, root).dependencies) == 0)
	resolver_init(&resolver, &store, test_resolve_declaration, &data, mem.nil_allocator())
	state, err = resolve_entity(&resolver, unused)
	allocation_error, allocation_failed = err.(runtime.Allocator_Error)
	testing.expect(t, state == .Unresolved && allocation_failed && allocation_error == .Out_Of_Memory && len(resolver.stack) == 0 && calls[unused] == 0)
}

@(private = "file")
test_resolve_declaration :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	data := (^Resolver_Test_Data)(user_data)
	data.calls[id] += 1
	entity := entity_get(resolver.scopes, id)
	assert(entity.state == .Resolving && entity.scope == data.file.scope)
	switch entity.name {
	case "Bad":
		entity.constant = 1
		return false, nil
	case "Fail":
		return false, runtime.Allocator_Error.Out_Of_Memory
	case "Grow":
		for _ in 0 ..< 128 {
			_, create_err := entity_create(resolver.scopes, Entity{name = "_", kind = .Constant, scope = data.file.scope})
			if create_err != nil { return false, create_err.(runtime.Allocator_Error) }
		}
	case "Nominal":
		nominal := types.reserve_nominal(data.type_store, .Struct, "Nominal")
		entity.type = nominal
		data.identity_state, err = resolve_dependency(resolver, Dependency{entity = id, kind = .Name}, .Type_Identity)
		if err != nil { return false, err }
		types.complete_nominal(data.type_store, nominal, types.Type{kind = .Struct, name = "Nominal"})
		return true, nil
	case:
		for declaration in data.collection.declarations {
			if declaration.entity != id || declaration.value.node == 0 { continue }
			node := data.file.ast.nodes[declaration.value.node]
			if node.kind != .Ident { continue }
			name := string(data.file.source[node.start:node.end])
			target, _ := scope_lookup(resolver.scopes, entity.scope, name)
			dependency := Dependency {
				entity = target,
				kind   = .Constant,
				source = {1, node.start, node.end},
			}
			_, err = resolve_dependency(resolver, dependency)
			if err != nil { return false, err }
			if entity_get(resolver.scopes, id).name == "Root" {
				_, err = resolve_dependency(resolver, dependency)
				if err != nil { return false, err }
				dependency.kind = .Name
				_, err = resolve_dependency(resolver, dependency)
				if err != nil { return false, err }
			}
		}
	}
	entity_get(resolver.scopes, id).type = data.integer
	return true, nil
}
