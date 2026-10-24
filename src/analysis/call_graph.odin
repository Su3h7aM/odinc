package analysis

import "base:runtime"
import "core:slice"
import "oc:check"

// Compressed rows: the neighbours of `id` are `targets[offsets[id]:offsets[id+1]]`, sorted and without repeats.
Adjacency :: struct {
	offsets: []u32,
	targets: []Procedure_Id,
}

Call_Graph :: struct {
	procedure_of_entity: []Procedure_Id,
	references:          Adjacency,
	referrers:           Adjacency,
	calls:               Adjacency,
	callers:             Adjacency,
	// Callees come before their callers; members of one cycle are adjacent and share a component.
	order:               []Procedure_Id,
	component:           []u32,
}

Edge :: struct {
	from, to: Procedure_Id,
}

adjacent :: proc(adjacency: Adjacency, id: Procedure_Id) -> []Procedure_Id {
	if int(id) + 1 >= len(adjacency.offsets) { return nil }
	return adjacency.targets[adjacency.offsets[id]:adjacency.offsets[int(id) + 1]]
}

@(private = "package")
call_graph_build :: proc(run: ^Run) -> (graph: Call_Graph, err: runtime.Allocator_Error) {
	program := run.program
	count := len(run.procedures)
	graph.procedure_of_entity = make([]Procedure_Id, len(program.entities), run.allocator) or_return
	for procedure, index in run.procedures[1:] {
		graph.procedure_of_entity[program.procedure_list[procedure.checked_index].entity] = Procedure_Id(index + 1)
	}
	references := make([dynamic]Edge, run.allocator) or_return
	calls := make([dynamic]Edge, run.allocator) or_return
	for procedure, index in run.procedures[1:] {
		from := Procedure_Id(index + 1)
		view := program.procedure_list[procedure.checked_index].view
		for event in run.events[procedure.events.first:][:procedure.events.count] {
			info := check.expression_info(program, view, event.expression.node)
			if target := call_graph_target(&graph, program, info.entity); target != 0 { append(&references, Edge{from, target}) or_return }
			if event.kind != .Call { continue }
			plan := check.plan(program, event.plan)
			if plan == nil { continue }
			call, is_call := plan^.(check.Call_Plan)
			if !is_call { continue }
			for entity in ([2]check.Entity_Id{call.entity, call.deferred}) {
				target := call_graph_target(&graph, program, entity)
				if target == 0 { continue }
				append(&calls, Edge{from, target}) or_return
				append(&references, Edge{from, target}) or_return
			}
		}
	}
	graph.references = adjacency_build(references[:], count, false, run.allocator) or_return
	graph.referrers = adjacency_build(references[:], count, true, run.allocator) or_return
	graph.calls = adjacency_build(calls[:], count, false, run.allocator) or_return
	graph.callers = adjacency_build(calls[:], count, true, run.allocator) or_return
	graph.order, graph.component = strongly_connected(graph.references, run.allocator) or_return
	return
}

@(private = "file")
call_graph_target :: proc(graph: ^Call_Graph, program: ^check.Checked_Program, entity: check.Entity_Id) -> Procedure_Id {
	entity := entity
	for _ in 0 ..< 8 {
		if entity == 0 || int(entity) >= len(program.entities) { return 0 }
		if target := graph.procedure_of_entity[entity]; target != 0 { return target }
		alias := program.entities[entity].alias
		if alias == 0 || alias == entity { return 0 }
		entity = alias
	}
	return 0
}

adjacency_build :: proc(edges: []Edge, count: int, reversed: bool, allocator: runtime.Allocator) -> (adjacency: Adjacency, err: runtime.Allocator_Error) {
	adjacency.offsets = make([]u32, count + 1, allocator) or_return
	cursor := make([]u32, count + 1, allocator) or_return
	defer delete(cursor, allocator)
	for edge in edges {
		row := edge.to if reversed else edge.from
		adjacency.offsets[int(row) + 1] += 1
	}
	for index in 1 ..< len(adjacency.offsets) { adjacency.offsets[index] += adjacency.offsets[index - 1] }
	copy(cursor, adjacency.offsets)
	raw := make([]Procedure_Id, len(edges), allocator) or_return
	for edge in edges {
		row := edge.to if reversed else edge.from
		raw[cursor[row]] = edge.from if reversed else edge.to
		cursor[row] += 1
	}
	adjacency.targets = raw
	used := 0
	input_start := u32(0)
	for row in 0 ..< count {
		end := adjacency.offsets[row + 1]
		slice.sort(raw[input_start:end])
		row_start := used
		for target in raw[input_start:end] {
			if used > row_start && raw[used - 1] == target { continue }
			raw[used] = target
			used += 1
		}
		adjacency.offsets[row + 1] = u32(used)
		input_start = end
	}
	adjacency.targets = raw[:used]
	return
}

// Tarjan's algorithm with an explicit stack: components finish after everything they reach, so callees come first.
strongly_connected :: proc(graph: Adjacency, allocator: runtime.Allocator) -> (order: []Procedure_Id, component: []u32, err: runtime.Allocator_Error) {
	count := len(graph.offsets) - 1
	order = make([]Procedure_Id, max(count - 1, 0), allocator) or_return
	component = make([]u32, max(count, 0), allocator) or_return
	if count <= 0 { return }
	index := make([]u32, count, context.temp_allocator) or_return
	lowest := make([]u32, count, context.temp_allocator) or_return
	on_stack := make([]bool, count, context.temp_allocator) or_return
	next_edge := make([]u32, count, context.temp_allocator) or_return
	visit := make([dynamic]Procedure_Id, context.temp_allocator) or_return
	members := make([dynamic]Procedure_Id, context.temp_allocator) or_return
	counter, components, placed := u32(1), u32(0), 0
	for root in 1 ..< count {
		if index[root] != 0 { continue }
		append(&visit, Procedure_Id(root)) or_return
		index[root], lowest[root] = counter, counter
		counter += 1
		append(&members, Procedure_Id(root)) or_return
		on_stack[root] = true
		for len(visit) > 0 {
			current := visit[len(visit) - 1]
			neighbours := adjacent(graph, current)
			if int(next_edge[current]) < len(neighbours) {
				next := neighbours[next_edge[current]]
				next_edge[current] += 1
				if index[next] == 0 {
					index[next], lowest[next] = counter, counter
					counter += 1
					append(&members, next) or_return
					on_stack[next] = true
					append(&visit, next) or_return
				} else if on_stack[next] {
					lowest[current] = min(lowest[current], index[next])
				}
				continue
			}
			pop(&visit)
			if len(visit) > 0 {
				parent := visit[len(visit) - 1]
				lowest[parent] = min(lowest[parent], lowest[current])
			}
			if lowest[current] != index[current] { continue }
			components += 1
			for {
				member := pop(&members)
				on_stack[member] = false
				component[member] = components
				order[placed] = member
				placed += 1
				if member == current { break }
			}
		}
	}
	return
}
