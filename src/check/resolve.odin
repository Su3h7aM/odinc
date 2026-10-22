package check

import "base:runtime"
import "core:mem"
import "oc:types"

Resolver_Failure :: enum u8 {
	None,
	No_Callback,
	No_Active_Declaration,
}
Resolve_Error :: union #shared_nil {
	Resolver_Failure,
	Scope_Error,
	runtime.Allocator_Error,
}
Resolution_Need :: enum u8 {
	Complete,
	Type_Identity,
}
Resolution_Diagnostic_Kind :: enum u8 {
	None,
	Declaration_Cycle,
	Refers_To,
	Cycle_End,
}

// Placeholder for F3. Source spans refer to declarations, as check_expr.cpp check_cycle does.
Resolution_Diagnostic :: struct {
	kind:   Resolution_Diagnostic_Kind,
	entity: Entity_Id,
	name:   string,
	source: Source_Span,
}

// Checks in the entity's declaring scope, not its caller's scope. Prerequisites use resolve_dependency.
// False means a semantic error already diagnosed by the callback; errors abort resolution.
Declaration_Resolver :: #type proc(resolver: ^Resolver, entity: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error)

// Serial, exclusive semantic access to the borrowed scope store. Owns dependency slices and diagnostics.
// Keep alive while checked-program entities borrow its dependencies. Callbacks may grow entity storage.
Resolver :: struct {
	scopes:            ^Scope_Store,
	allocator:         mem.Allocator,
	check_declaration: Declaration_Resolver,
	check_body:        Declaration_Resolver,
	user_data:         rawptr,
	stack:             [dynamic]Entity_Id,
	dependencies:      [dynamic][dynamic]Dependency,
	diagnostics:       [dynamic]Resolution_Diagnostic,
	pending_bodies:    [dynamic]Entity_Id,
	body_pause_depth:  int,
	poisoned:          [dynamic]Entity_Id,
	instances:         Instance_Index,
}

resolver_init :: proc(resolver: ^Resolver, scopes: ^Scope_Store, callback: Declaration_Resolver, user_data: rawptr, allocator: mem.Allocator) {
	assert(resolver != nil && resolver.scopes == nil && scopes != nil && scopes.allocator.procedure != nil)
	assert(allocator.procedure != nil)
	for entity in scopes.entities { assert(len(entity.dependencies) == 0) }
	resolver.scopes = scopes
	resolver.allocator = allocator
	resolver.check_declaration = callback
	resolver.user_data = user_data
	resolver.stack.allocator = allocator
	resolver.dependencies.allocator = allocator
	resolver.diagnostics.allocator = allocator
	resolver.pending_bodies.allocator = allocator
	resolver.poisoned.allocator = allocator
}

resolver_destroy :: proc(resolver: ^Resolver) {
	if resolver == nil { return }
	assert(len(resolver.stack) == 0)
	for dependencies, index in resolver.dependencies {
		if entity := entity_get(resolver.scopes, Entity_Id(index)); entity != nil { entity.dependencies = nil }
		delete(dependencies)
	}
	delete(resolver.dependencies)
	delete(resolver.stack)
	delete(resolver.diagnostics)
	delete(resolver.pending_bodies)
	delete(resolver.poisoned)
	instance_index_destroy(&resolver.instances)
	resolver^ = {}
}

// T1 may request an already-published nominal identity through a pointer/slice, never its layout.
// Callback/allocation errors poison active declarations and abort the checking session, not a retry.
@(require_results)
resolve_entity :: proc(resolver: ^Resolver, id: Entity_Id, need := Resolution_Need.Complete) -> (state: Resolution_State, err: Resolve_Error) {
	state, err = resolve_entity_signature(resolver, id, need)
	if err != nil || len(resolver.stack) != 0 { return }
	err = resolver_check_pending_bodies(resolver)
	return
}

// Bodies wait until no declaration is active, so a body may refer to any procedure without a declaration cycle.
@(private = "package")
resolver_check_pending_bodies :: proc(resolver: ^Resolver) -> Resolve_Error {
	if resolver.body_pause_depth > 0 { return nil }
	for len(resolver.pending_bodies) > 0 {
		id := pop_front(&resolver.pending_bodies)
		if resolver.check_body == nil { return Resolver_Failure.No_Callback }
		_, body_err := resolver.check_body(resolver, id, resolver.user_data)
		if body_err != nil { return body_err }
	}
	return nil
}

@(private = "file")
resolve_entity_signature :: proc(resolver: ^Resolver, id: Entity_Id, need: Resolution_Need) -> (state: Resolution_State, err: Resolve_Error) {
	if resolver == nil || resolver.scopes == nil { return .Invalid, Scope_Error.Uninitialized }
	entity := entity_get(resolver.scopes, id)
	if entity == nil { return .Invalid, Scope_Error.Invalid_Entity }
	switch entity.state {
	case .Resolved:
		return .Resolved, nil
	case .Invalid:
		resolver_poison(resolver, id)
		return .Invalid, nil
	case .Resolving:
		if need == .Type_Identity && entity.kind == .Type_Name && entity.type != 0 && entity.type != types.TYPE_POISON {
			return .Resolving, nil
		}
		state = .Invalid
		resolver_report_cycle(resolver, id) or_return
		return .Invalid, nil
	case .Unresolved:
	}
	if resolver.check_declaration == nil { return .Unresolved, Resolver_Failure.No_Callback }
	_, stack_err := append(&resolver.stack, id)
	if stack_err != nil { return .Unresolved, stack_err }
	entity_get(resolver.scopes, id).state = .Resolving
	defer {
		assert(pop(&resolver.stack) == id)
	}
	valid, callback_err := resolver.check_declaration(resolver, id, resolver.user_data)
	entity = entity_get(resolver.scopes, id)
	if callback_err != nil || !valid || entity.state == .Invalid || entity.type == types.TYPE_POISON {
		resolver_poison(resolver, id)
		return .Invalid, callback_err
	}
	entity.state = .Resolved
	return .Resolved, nil
}

// Records the first source for each target/kind pair in encounter order, including cyclic edges.
@(require_results)
resolve_dependency :: proc(resolver: ^Resolver, dependency: Dependency, need := Resolution_Need.Complete) -> (state: Resolution_State, err: Resolve_Error) {
	if resolver == nil || resolver.scopes == nil { return .Invalid, Scope_Error.Uninitialized }
	if entity_get(resolver.scopes, dependency.entity) == nil { return .Invalid, Scope_Error.Invalid_Entity }
	if len(resolver.stack) == 0 { return .Invalid, Resolver_Failure.No_Active_Declaration }
	owner := resolver.stack[len(resolver.stack) - 1]
	for len(resolver.dependencies) <= int(owner) {
		list: [dynamic]Dependency
		list.allocator = resolver.allocator
		append(&resolver.dependencies, list) or_return
	}
	dependencies := &resolver.dependencies[owner]
	found := false
	for previous in dependencies {
		if previous.entity == dependency.entity && previous.kind == dependency.kind { found = true; break }
	}
	if !found {
		append(dependencies, dependency) or_return
		entity_get(resolver.scopes, owner).dependencies = dependencies[:]
	}
	state, err = resolve_entity(resolver, dependency.entity, need)
	if err != nil || state == .Invalid { resolver_poison(resolver, owner) }
	return
}

resolution_diagnostic_format :: proc(kind: Resolution_Diagnostic_Kind) -> string {
	switch kind {
	case .None:
		return ""
	case .Declaration_Cycle:
		return "Illegal declaration cycle of `%s`"
	case .Refers_To:
		return "\t%s refers to"
	case .Cycle_End:
		return "\t%s"
	}
	unreachable()
}

@(private = "file")
resolver_poison :: proc(resolver: ^Resolver, id: Entity_Id) {
	entity := entity_get(resolver.scopes, id)
	if entity.state != .Invalid { _, _ = append(&resolver.poisoned, id) }
	entity.state = .Invalid
	entity.type = types.TYPE_POISON
	entity.constant = 0
}

// Resets the entities poisoned since `mark` to Unresolved, so a later attempt resolves them again.
@(private = "package")
resolver_rollback_poison :: proc(resolver: ^Resolver, mark: int) {
	for id in resolver.poisoned[mark:] {
		entity := entity_get(resolver.scopes, id)
		entity.state = .Unresolved
		entity.type = types.TYPE_NONE
		entity.constant = 0
		entity.dependencies = nil
		if int(id) < len(resolver.dependencies) { clear(&resolver.dependencies[id]) }
	}
	resize(&resolver.poisoned, mark)
}

@(private = "file")
resolver_report_cycle :: proc(resolver: ^Resolver, id: Entity_Id) -> (err: runtime.Allocator_Error) {
	start := -1
	for active, index in resolver.stack {
		if active == id { start = index; break }
	}
	assert(start >= 0)
	for active in resolver.stack[start:] { resolver_poison(resolver, active) }
	resolver_append_diagnostic(resolver, id, .Declaration_Cycle) or_return
	for active in resolver.stack[start:] {
		resolver_append_diagnostic(resolver, active, .Refers_To) or_return
	}
	resolver_append_diagnostic(resolver, id, .Cycle_End) or_return
	return nil
}

@(private = "file")
resolver_append_diagnostic :: proc(resolver: ^Resolver, id: Entity_Id, kind: Resolution_Diagnostic_Kind) -> runtime.Allocator_Error {
	entity := entity_get(resolver.scopes, id)
	_, err := append(
		&resolver.diagnostics,
		Resolution_Diagnostic {
			kind = kind,
			entity = id,
			name = entity.name,
			source = {entity.declaration.file, entity.order.offset, entity.order.offset + u32(len(entity.name))},
		},
	)
	return err
}
