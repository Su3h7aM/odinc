package analysis

import "base:runtime"
import "core:hash"
import "core:mem"
import "oc:check"
import "oc:types"

Value_Id :: distinct u32
Object_Id :: distinct u32
Path_Id :: distinct u32

Path_Step :: struct {
	kind:        enum u8 {
		Field,
		Element,
		Dereference,
	},
	owner_type:  types.Type_Id,
	field_index: u32,
}
Path :: struct {
	parent: Path_Id,
	step:   Path_Step,
	depth:  u32,
}
Path_Key :: struct {
	parent: Path_Id,
	step:   Path_Step,
}
Origin_Kind :: enum u8 {
	Invalid,
	Local,
	Temporary,
	Variadic,
	Parameter,
	Parameter_Load,
	Parameter_Deep,
	Outer,
	Owned,
}
Origin :: struct {
	kind:        Origin_Kind,
	object:      Object_Id,
	path:        Path_Id,
	offset_lost: bool,
}
Value_Fact :: struct {
	path:     Path_Id,
	origin:   Origin,
	definite: bool,
}
Value_Operation :: enum u8 {
	Constant,
	Parameter,
	Address,
	Read_Local,
	Copy,
	Project,
	Aggregate,
	Convert,
	Call_Result,
	Phi,
	Refine,
	Load,
	Store,
}
Value :: struct {
	operation:     Value_Operation,
	expression:    check.Expression_Ref,
	type:          types.Type_Id,
	inputs, facts: Index_Range,
}
Object :: struct {
	procedure:     Procedure_Id,
	entity:        check.Entity_Id,
	temporary:     check.Expression_Ref,
	type:          types.Type_Id,
	address_taken: bool,
}
Graph :: struct {
	values:  [dynamic]Value,
	inputs:  [dynamic]Value_Id,
	facts:   [dynamic]Value_Fact,
	objects: [dynamic]Object,
	paths:   [dynamic]Path,
}

@(private = "package")
Escape :: struct {
	run:               ^Run,
	graph:             Graph,
	path_index:        map[Path_Key]Path_Id,
	fact_index:        map[u64][dynamic]Index_Range,
	entity_objects:    []Object_Id,
	temporary_objects: map[check.Expression_Ref]Object_Id,
	memory:            [dynamic]Value_Id,
	procedure:         Procedure_Id,
	view:              check.View_Id,
	variadic:          check.Entity_Id,
	reachable:         bool,
}

@(private = "package")
escape_graph_init :: proc(escape: ^Escape, run: ^Run) -> runtime.Allocator_Error {
	escape.run = run
	allocator := run.allocator
	escape.graph = {
		values  = make([dynamic]Value, 0, allocator) or_return,
		inputs  = make([dynamic]Value_Id, 0, allocator) or_return,
		facts   = make([dynamic]Value_Fact, 0, allocator) or_return,
		objects = make([dynamic]Object, 0, allocator) or_return,
		paths   = make([dynamic]Path, 0, allocator) or_return,
	}
	escape.path_index = make(map[Path_Key]Path_Id, allocator)
	escape.fact_index = make(map[u64][dynamic]Index_Range, allocator)
	escape.temporary_objects = make(map[check.Expression_Ref]Object_Id, allocator)
	escape.entity_objects = make([]Object_Id, len(run.program.entities), allocator) or_return
	escape.memory = make([dynamic]Value_Id, 0, allocator) or_return
	append(&escape.graph.values, Value{}) or_return
	append(&escape.graph.objects, Object{}) or_return
	append(&escape.graph.paths, Path{}) or_return
	append(&escape.memory, Value_Id(0)) or_return
	return nil
}

@(private = "package")
escape_path :: proc(escape: ^Escape, parent: Path_Id, step: Path_Step) -> (id: Path_Id, err: runtime.Allocator_Error) {
	key := Path_Key{parent, step}
	if existing, ok := escape.path_index[key]; ok { return existing, nil }
	id = Path_Id(len(escape.graph.paths))
	append(&escape.graph.paths, Path{parent, step, escape.graph.paths[parent].depth + 1}) or_return
	escape.path_index[key] = id
	return
}

@(private = "package")
escape_path_concat :: proc(escape: ^Escape, prefix, path: Path_Id) -> (result: Path_Id, err: runtime.Allocator_Error) {
	if path == 0 { return prefix, nil }
	entry := escape.graph.paths[path]
	parent := escape_path_concat(escape, prefix, entry.parent) or_return
	return escape_path(escape, parent, entry.step)
}

@(private = "package")
escape_path_suffix :: proc(escape: ^Escape, path: Path_Id, prefix_depth: u32) -> (result: Path_Id, err: runtime.Allocator_Error) {
	entry := escape.graph.paths[path]
	if entry.depth <= prefix_depth { return 0, nil }
	parent := escape_path_suffix(escape, entry.parent, prefix_depth) or_return
	return escape_path(escape, parent, entry.step)
}

@(private = "package")
escape_path_has_prefix :: proc(escape: ^Escape, path, prefix: Path_Id) -> bool {
	path := path
	depth := escape.graph.paths[prefix].depth
	for escape.graph.paths[path].depth > depth { path = escape.graph.paths[path].parent }
	return path == prefix
}

@(private = "package")
escape_value :: proc(
	escape: ^Escape,
	operation: Value_Operation,
	expression: check.Expression_Ref,
	facts: []Value_Fact = nil,
	inputs: []Value_Id = nil,
) -> (
	id: Value_Id,
	err: runtime.Allocator_Error,
) {
	value := Value {
		operation  = operation,
		expression = expression,
	}
	if expression.node != 0 { value.type = check.expression_info(escape.run.program, expression.view, expression.node).type }
	value.facts = escape_fact_set(escape, facts) or_return
	value.inputs = {u32(len(escape.graph.inputs)), u32(len(inputs))}
	append(&escape.graph.inputs, ..inputs) or_return
	id = Value_Id(len(escape.graph.values))
	append(&escape.graph.values, value) or_return
	return
}

@(private = "file")
escape_fact_set :: proc(escape: ^Escape, facts: []Value_Fact) -> (result: Index_Range, err: runtime.Allocator_Error) {
	if len(facts) == 0 { return }
	fingerprint := hash.fnv64a(nil)
	for fact in facts {
		words := [2]u64 {
			u64(fact.path) << 32 | u64(fact.origin.object),
			u64(fact.origin.path) << 32 | u64(fact.origin.kind) << 2 | u64(fact.origin.offset_lost) << 1 | u64(fact.definite),
		}
		fingerprint = hash.fnv64a(mem.slice_to_bytes(words[:]), fingerprint)
	}
	bucket := escape.fact_index[fingerprint]
	for candidate in bucket {
		if int(candidate.count) != len(facts) { continue }
		equal := true
		for fact, index in facts {
			if escape.graph.facts[int(candidate.first) + index] != fact { equal = false; break }
		}
		if equal { return candidate, nil }
	}
	if bucket.allocator.procedure == nil { bucket = make([dynamic]Index_Range, 0, escape.run.allocator) or_return }
	result = {u32(len(escape.graph.facts)), u32(len(facts))}
	append(&escape.graph.facts, ..facts) or_return
	append(&bucket, result) or_return
	escape.fact_index[fingerprint] = bucket
	return
}

@(private = "package")
escape_facts :: proc(escape: ^Escape, value: Value_Id) -> []Value_Fact {
	range := escape.graph.values[value].facts
	return escape.graph.facts[range.first:range.first + range.count]
}

@(private = "package")
escape_origin_value :: proc(escape: ^Escape, expression: check.Expression_Ref, origin: Origin) -> (result: Value_Id, err: runtime.Allocator_Error) {
	operation: Value_Operation = .Parameter if origin.kind == .Parameter || origin.kind == .Variadic else .Address
	return escape_value(escape, operation, expression, []Value_Fact{{origin = origin, definite = origin.kind == .Local || origin.kind == .Temporary}})
}

@(private = "package")
escape_object :: proc(escape: ^Escape, entity: check.Entity_Id, expression: check.Expression_Ref = {}) -> (id: Object_Id, err: runtime.Allocator_Error) {
	if entity != 0 {
		if existing := escape.entity_objects[entity]; existing != 0 && escape.graph.objects[existing].procedure == escape.procedure { return existing, nil }
	} else if existing, ok := escape.temporary_objects[expression]; ok { return existing, nil }
	id = Object_Id(len(escape.graph.objects))
	object := Object {
		procedure = escape.procedure,
		entity    = entity,
		temporary = expression,
	}
	if entity !=
	   0 { object.type = escape.run.program.entities[entity].type } else { object.type = check.expression_info(escape.run.program, expression.view, expression.node).type }
	append(&escape.graph.objects, object) or_return
	append(&escape.memory, Value_Id(0)) or_return
	if entity != 0 { escape.entity_objects[entity] = id } else { escape.temporary_objects[expression] = id }
	return
}

@(private = "package")
escape_add_fact :: proc(facts: ^[dynamic]Value_Fact, fact: Value_Fact) -> runtime.Allocator_Error {
	for &existing in facts {
		if existing.path == fact.path && existing.origin == fact.origin {
			existing.definite |= fact.definite
			return nil
		}
	}
	append(facts, fact) or_return
	return nil
}

@(private = "package")
escape_origin_within :: proc(escape: ^Escape, origin: Origin, path: Path_Id, prefix_depth: u32) -> (result: Origin, err: runtime.Allocator_Error) {
	result = origin
	if origin.kind != .Parameter { return }
	for current := origin.path; current != 0; current = escape.graph.paths[current].parent {
		if escape.graph.paths[current].step.kind == .Dereference { return }
	}
	extra := escape_path_suffix(escape, path, prefix_depth) or_return
	result.path = escape_path_concat(escape, origin.path, extra) or_return
	return
}

@(private = "package")
escape_project_fact :: proc(escape: ^Escape, facts: ^[dynamic]Value_Fact, fact: Value_Fact, path: Path_Id) -> runtime.Allocator_Error {
	fact := fact
	if escape_path_has_prefix(escape, fact.path, path) {
		fact.path = escape_path_suffix(escape, fact.path, escape.graph.paths[path].depth) or_return
	} else if escape_path_has_prefix(escape, path, fact.path) {
		fact.origin = escape_origin_within(escape, fact.origin, path, escape.graph.paths[fact.path].depth) or_return
		fact.path = 0
	} else { return nil }
	return escape_add_fact(facts, fact)
}

@(private = "package")
escape_project :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	value: Value_Id,
	path: Path_Id,
	read: bool = false,
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	facts := make([dynamic]Value_Fact, 0, escape.run.allocator) or_return
	for fact in escape_facts(escape, value) {
		fact := fact
		if read { fact.definite = false }
		escape_project_fact(escape, &facts, fact, path) or_return
	}
	return escape_value(escape, .Read_Local if read else .Project, expression, facts[:], []Value_Id{value})
}

@(private = "package")
escape_pointer_offset :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
	value: Value_Id,
	path: Path_Id,
) -> (
	result: Value_Id,
	err: runtime.Allocator_Error,
) {
	facts := make([dynamic]Value_Fact, 0, escape.run.allocator) or_return
	for fact in escape_facts(escape, value) {
		fact := fact
		fact.path = 0
		#partial switch fact.origin.kind {
		case .Local, .Temporary, .Owned:
			fact.origin.path = escape_path_concat(escape, fact.origin.path, path) or_return
		case .Parameter:
			if path != 0 {
				has_dereference := false
				for current := fact.origin.path; current != 0; current = escape.graph.paths[current].parent {
					has_dereference |= escape.graph.paths[current].step.kind == .Dereference
				}
				if !has_dereference { fact.origin.path = escape_path(escape, fact.origin.path, {kind = .Dereference}) or_return }
				fact.origin.path = escape_path_concat(escape, fact.origin.path, path) or_return
			}
		case .Parameter_Load, .Parameter_Deep:
			fact.origin.offset_lost |= path != 0
		}
		escape_add_fact(&facts, fact) or_return
	}
	return escape_value(escape, .Project, expression, facts[:], []Value_Id{value})
}
