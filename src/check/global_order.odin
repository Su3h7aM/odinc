package check

import "base:runtime"

// Orders dynamic package variables so that each initializer runs after the dynamic variables it reaches,
// directly or through the entities it depends on (procedures included). Source order breaks ties.
@(private = "package")
global_initialization_order :: proc(
	checker: ^Expression_Checker,
	globals: []Global,
	allocator: runtime.Allocator,
) -> (
	order: []Entity_Id,
	err: runtime.Allocator_Error,
) {
	entities := checker.type_checker.resolver.scopes.entities[:]
	visited := make([]bool, len(entities), allocator) or_return
	is_dynamic := make([]bool, len(entities), allocator) or_return
	for global in globals {
		if global.initializer_node.node != 0 && global.initializer == 0 { is_dynamic[global.entity] = true }
	}
	sequence := make([dynamic]Entity_Id, allocator) or_return
	for global in globals {
		if is_dynamic[global.entity] { visit_initialization_dependency(entities, is_dynamic, visited, &sequence, global.entity) or_return }
	}
	return sequence[:], nil
}

@(private = "file")
visit_initialization_dependency :: proc(
	entities: []Entity,
	is_dynamic, visited: []bool,
	sequence: ^[dynamic]Entity_Id,
	entity: Entity_Id,
) -> runtime.Allocator_Error {
	if visited[entity] { return nil }
	visited[entity] = true
	for dependency in entities[entity].dependencies {
		visit_initialization_dependency(entities, is_dynamic, visited, sequence, dependency.entity) or_return
	}
	if is_dynamic[entity] { append(sequence, entity) or_return }
	return nil
}
