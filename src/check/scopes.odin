package check

import "base:runtime"
import "core:mem"

Scope_Error :: enum u8 {
	None,
	Uninitialized,
	Invalid_Scope,
	Invalid_Entity,
	Invalid_Kind,
	Handle_Limit,
}
Binding_Error :: union #shared_nil {
	Scope_Error,
	runtime.Allocator_Error,
}

// Owns tables, declaration lists and lookup maps. Entity metadata and name bytes are borrowed.
// Borrowed records/slices must be reacquired after mutation; do not mutate after publication.
Scope_Store :: struct {
	allocator:          mem.Allocator,
	entities:           [dynamic]Entity,
	scopes:             [dynamic]Scope,
	scope_declarations: [dynamic][dynamic]Entity_Id,
}

@(require_results)
scope_store_init :: proc(store: ^Scope_Store, allocator: mem.Allocator) -> (err: runtime.Allocator_Error) {
	assert(store != nil && len(store.entities) == 0 && len(store.scopes) == 0 && len(store.scope_declarations) == 0)
	assert(allocator.procedure != nil)
	store.allocator = allocator
	defer if err != nil { scope_store_destroy(store) }
	store.entities.allocator = allocator
	store.scopes.allocator = allocator
	store.scope_declarations.allocator = allocator
	append(&store.entities, Entity{}) or_return
	append(&store.scopes, Scope{}) or_return
	append(&store.scope_declarations, [dynamic]Entity_Id{}) or_return
	return nil
}

scope_store_destroy :: proc(store: ^Scope_Store) {
	if store == nil { return }
	for &scope in store.scopes { delete(scope.lookup) }
	for declarations in store.scope_declarations { delete(declarations) }
	delete(store.scope_declarations)
	delete(store.scopes)
	delete(store.entities)
	store^ = {}
}

@(require_results)
scope_create :: proc(
	store: ^Scope_Store,
	parent: Scope_Id,
	kind: Scope_Kind,
	owner: Entity_Id = 0,
	order: Source_Order = {},
) -> (
	id: Scope_Id,
	err: Binding_Error,
) {
	if !scope_store_ready(store) { return 0, Scope_Error.Uninitialized }
	if parent != 0 && scope_get(store, parent) == nil { return 0, Scope_Error.Invalid_Scope }
	if owner != 0 && entity_get(store, owner) == nil { return 0, Scope_Error.Invalid_Entity }
	if kind == .Invalid { return 0, Scope_Error.Invalid_Kind }
	if u64(len(store.scopes)) > u64(max(u32)) { return 0, Scope_Error.Handle_Limit }
	lookup := make(map[string]Entity_Id, store.allocator)
	append(&store.scopes, Scope{parent = parent, kind = kind, owner = owner, order = order, lookup = lookup}) or_return
	created := Scope_Id(len(store.scopes) - 1)
	defer if err != nil {
		delete(pop(&store.scopes).lookup)
	}
	declarations: [dynamic]Entity_Id
	declarations.allocator = store.allocator
	append(&store.scope_declarations, declarations) or_return
	return created, nil
}

// Records declaration order without publishing the name.
@(require_results)
entity_create :: proc(store: ^Scope_Store, descriptor: Entity) -> (id: Entity_Id, err: Binding_Error) {
	if !scope_store_ready(store) { return 0, Scope_Error.Uninitialized }
	scope := scope_get(store, descriptor.scope)
	if scope == nil { return 0, Scope_Error.Invalid_Scope }
	if u64(len(store.entities)) > u64(max(u32)) { return 0, Scope_Error.Handle_Limit }
	append(&store.entities, descriptor) or_return
	created := Entity_Id(len(store.entities) - 1)
	defer if err != nil {
		pop(&store.entities)
	}
	declarations := &store.scope_declarations[descriptor.scope]
	append(declarations, created) or_return
	scope.declarations = declarations[:]
	return created, nil
}

// Returned pointers are borrowed and may be invalidated by the next mutation.
entity_get :: proc(store: ^Scope_Store, id: Entity_Id) -> ^Entity {
	if store == nil || id == 0 || u64(id) >= u64(len(store.entities)) { return nil }
	return &store.entities[id]
}

scope_get :: proc(store: ^Scope_Store, id: Scope_Id) -> ^Scope {
	if store == nil || id == 0 || u64(id) >= u64(len(store.scopes)) { return nil }
	return &store.scopes[id]
}

// Returns the conflicting entity, or zero for a new/repeated/blank binding.
@(require_results)
scope_insert :: proc(store: ^Scope_Store, scope: Scope_Id, entity: Entity_Id) -> (previous: Entity_Id, err: Binding_Error) {
	if !scope_store_ready(store) { return 0, Scope_Error.Uninitialized }
	declaration := entity_get(store, entity)
	if declaration == nil { return 0, Scope_Error.Invalid_Entity }
	return scope_insert_with_name(store, scope, declaration.name, entity)
}

// Aliases retain the entity's declaring scope and never duplicate its declaration list entry.
// Collision rules follow the fork's checker.cpp, scope_insert_with_name.
@(require_results)
scope_insert_with_name :: proc(store: ^Scope_Store, scope: Scope_Id, name: string, entity: Entity_Id) -> (previous: Entity_Id, err: Binding_Error) {
	if !scope_store_ready(store) { return 0, Scope_Error.Uninitialized }
	destination := scope_get(store, scope)
	if destination == nil { return 0, Scope_Error.Invalid_Scope }
	if entity_get(store, entity) == nil { return 0, Scope_Error.Invalid_Entity }
	if name == "" || name == "_" { return 0, nil }
	// One probe finds an existing binding or reserves the slot; the
	// procedure-parent shadow check only runs for a reserved slot.
	_, slot, inserted, insert_err := map_entry(&destination.lookup, name)
	if insert_err != nil { return 0, insert_err }
	if !inserted {
		previous = slot^
		if previous == entity { previous = 0 }
		return previous, nil
	}
	if parent := scope_get(store, destination.parent); parent != nil && parent.kind == .Procedure {
		candidate := scope_lookup_current(store, destination.parent, name)
		if declaration := entity_get(store, candidate); declaration != nil {
			if .Result in declaration.flags { previous = candidate }
			if .Parameter in declaration.flags {
				for &binding in parent.using_bindings {
					if binding.entity == candidate { previous = candidate; break }
				}
			}
		}
	}
	if previous == 0 {
		slot^ = entity
		return 0, nil
	}
	// Conflict: withdraw the reserved slot so the map is unchanged.
	delete_key(&destination.lookup, name)
	if previous == entity { previous = 0 }
	return previous, nil
}

scope_lookup_current :: proc(store: ^Scope_Store, scope: Scope_Id, name: string) -> Entity_Id {
	if name == "" || name == "_" { return 0 }
	current := scope_get(store, scope)
	if current == nil { return 0 }
	return current.lookup[name]
}

// Procedure boundaries hide enclosing runtime locals and labels, as scope_lookup_parent does.
// Declarations in a procedure body resolve in the active procedure instance; package and file scopes do not.
scope_inside_body :: proc(store: ^Scope_Store, scope: Scope_Id) -> bool {
	for current := scope_get(store, scope); current != nil; current = scope_get(store, current.parent) {
		if current.kind == .Procedure || current.kind == .Block { return true }
	}
	return false
}

// Resolves a name that the program refers to, so the entity counts as used, as check_ident does in the official checker.
scope_lookup :: proc(store: ^Scope_Store, scope: Scope_Id, name: string) -> (entity: Entity_Id, found_scope: Scope_Id) {
	entity, found_scope = scope_find(store, scope, name)
	if found := entity_get(store, entity); found != nil { found.flags += {.Used} }
	return
}

// Procedure boundaries hide enclosing runtime locals and labels, as scope_lookup_parent does. Does not mark the entity used.
scope_find :: proc(store: ^Scope_Store, scope: Scope_Id, name: string) -> (entity: Entity_Id, found_scope: Scope_Id) {
	if name == "" || name == "_" { return }
	crossed_procedure := false
	current_scope := scope
	for current := scope_get(store, current_scope); current != nil; current = scope_get(store, current_scope) {
		candidate: Entity_Id
		found := false
		if len(current.lookup) > 0 { candidate, found = current.lookup[name] }
		declaration := entity_get(store, candidate) if found else nil
		if declaration != nil {
			visible := true
			if crossed_procedure {
				if declaration.kind == .Label { visible = false }
				if declaration.kind == .Variable {
					declaring_scope := scope_get(store, declaration.scope)
					visible = declaring_scope != nil && (declaring_scope.kind == .File || declaring_scope.kind == .Package)
					if variable, ok := declaration.data.(Variable_Data); ok {
						visible = visible || variable.storage == .Global || variable.storage == .Thread_Local
					}
				}
			}
			if visible { return candidate, current_scope }
		}
		if current.kind == .Procedure { crossed_procedure = true }
		current_scope = current.parent
	}
	return
}

@(private = "file")
scope_store_ready :: proc(store: ^Scope_Store) -> bool {
	return(
		store != nil &&
		store.allocator.procedure != nil &&
		len(store.entities) > 0 &&
		len(store.scopes) > 0 &&
		len(store.scope_declarations) == len(store.scopes) \
	)
}
