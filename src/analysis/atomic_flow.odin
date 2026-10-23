package analysis

import "oc:syntax"

Fence_Kind :: enum u8 {
	Acquire,
	Release,
	Seq_Cst,
}

atomic_call_at :: proc(a: ^Atomics, site: Site) -> Atomic_Call {
	if index, ok := a.call_index[site]; ok { return a.calls[index] }
	return {}
}

// The procedure's calls with where each runs; filled by scanning its body once.
atomic_procedure :: proc(a: ^Atomics, id: Procedure_Id) -> ^Atomic_Procedure {
	p := &a.procedures[id]
	if p.ready { return p }
	p.ready = true
	p.places = make([dynamic]Placed_Call, a.allocator)
	p.acquires = make([dynamic]syntax.Node_Index, a.allocator)
	p.releases = make([dynamic]syntax.Node_Index, a.allocator)
	p.signal_acquires = make([dynamic]syntax.Node_Index, a.allocator)
	p.signal_releases = make([dynamic]syntax.Node_Index, a.allocator)
	scan := atomic_scan_init(a, id)
	p.view = scan.view
	scan.places = &p.places
	_ = atomic_scan(&scan, a.program.procedure_list[a.run.procedures[id].checked_index].body.node, false)
	return p
}

atomic_find_place :: proc(p: ^Atomic_Procedure, call: syntax.Node_Index) -> ^Atomic_Place {
	for &placed in p.places {
		if placed.call == call { return &placed.place }
	}
	return nil
}

// Whether `x` may run before `y`, both calls within one procedure.
atomic_may_precede :: proc(a: ^Atomics, p: ^Atomic_Procedure, x, y: syntax.Node_Index) -> bool {
	px, py := atomic_find_place(p, x), atomic_find_place(p, y)
	if px == nil || py == nil || px.deferred || py.deferred { return true }
	if px.loop != 0 && px.loop == py.loop { return true }
	ast := atomic_ast(a, p.view)
	for index in 0 ..< min(len(px.arms), len(py.arms)) {
		if px.arms[index].branch != py.arms[index].branch { break }
		if px.arms[index].arm != py.arms[index].arm { return false }
	}
	return ast.nodes[x].start < ast.nodes[y].start
}

// Whether an acquire fence may run after a call, or a release fence before it.
atomic_fenced :: proc(a: ^Atomics, p: ^Atomic_Procedure, fences: []syntax.Node_Index, call: syntax.Node_Index, acquire: bool) -> bool {
	for fence in fences {
		if acquire && atomic_may_precede(a, p, call, fence) { return true }
		if !acquire && atomic_may_precede(a, p, fence, call) { return true }
	}
	return false
}

atomic_has_fence :: proc(a: ^Atomics, id: Procedure_Id, kind: Fence_Kind) -> bool {
	p := &a.procedures[id]
	switch kind {
	case .Acquire:
		return len(p.acquires) > 0
	case .Release:
		return len(p.releases) > 0
	case .Seq_Cst:
		return p.has_seq_cst
	}
	return false
}

// Everything `from` may reach by references, marking each in `covered`.
atomic_cover :: proc(a: ^Atomics, covered: []bool, from: Procedure_Id) {
	if covered[from] { return }
	covered[from] = true
	clear(&a.queue)
	append(&a.queue, from)
	for index := 0; index < len(a.queue); index += 1 {
		for next in adjacent(a.graph.references, a.queue[index]) {
			if covered[next] { continue }
			covered[next] = true
			append(&a.queue, next)
		}
	}
}

atomic_reaches_fence :: proc(a: ^Atomics, from: Procedure_Id, kind: Fence_Kind) -> bool {
	a.stamp_mark += 1
	mark := a.stamp_mark
	clear(&a.queue)
	a.stamp[from] = mark
	append(&a.queue, from)
	for index := 0; index < len(a.queue); index += 1 {
		current := a.queue[index]
		if atomic_has_fence(a, current, kind) { return true }
		for next in adjacent(a.graph.references, current) {
			if a.stamp[next] == mark { continue }
			a.stamp[next] = mark
			append(&a.queue, next)
		}
	}
	return false
}

// Whether a call of `p` that may run before or after `call` reaches a fence.
atomic_fence_around :: proc(a: ^Atomics, p: ^Atomic_Procedure, call: syntax.Node_Index, acquire: bool) -> bool {
	for placed in p.places {
		callee, _ := atomic_callee(a, p.view, placed.call)
		target := atomic_callee_procedure(a, callee)
		if target == 0 { continue }
		if acquire && !atomic_may_precede(a, p, call, placed.call) || !acquire && !atomic_may_precede(a, p, placed.call, call) { continue }
		if atomic_reaches_fence(a, target, .Acquire if acquire else .Release) { return true }
	}
	return false
}

atomic_fence_called_by :: proc(a: ^Atomics, start: Procedure_Id, acquire: bool) -> bool {
	visited := make([]bool, len(a.procedures), context.temp_allocator)
	queue := make([dynamic]Procedure_Id, context.temp_allocator)
	append(&queue, start)
	visited[start] = true
	fenced := false
	for index := 0; index < len(queue) && !fenced; index += 1 {
		callee := queue[index]
		for caller in adjacent(a.graph.referrers, callee) {
			p := atomic_procedure(a, caller)
			for placed in p.places {
				entity, _ := atomic_callee(a, p.view, placed.call)
				if atomic_callee_procedure(a, entity) == callee && atomic_fence_around(a, p, placed.call, acquire) { fenced = true }
			}
			if !visited[caller] {
				visited[caller] = true
				append(&queue, caller)
			}
		}
	}
	return fenced
}

atomic_fence_called :: proc(a: ^Atomics, sites: []Atomic_Site, location: Location, acquire: bool) -> bool {
	for site in sites {
		if site.location != location { continue }
		p := atomic_procedure(a, site.procedure)
		if atomic_fence_around(a, p, site.call.node, acquire) || atomic_fence_called_by(a, site.procedure, acquire) { return true }
	}
	return false
}

AtomicStoreLoad :: struct {
	store, load: ^Atomic_Access,
}

atomic_seq_cst_ordered :: proc(a: ^Atomics, pair: AtomicStoreLoad) -> bool {
	if pair.store.seq_cst && pair.load.seq_cst { return true }
	p := atomic_procedure(a, pair.store.procedure)
	ast := atomic_ast(a, p.view)
	from, to := ast.nodes[pair.store.call.node].start, ast.nodes[pair.load.call.node].start
	for placed in p.places {
		position := ast.nodes[placed.call].start
		if from >= position || position >= to { continue }
		for fence in p.acquires {
			if fence != placed.call { continue }
			arguments := atomic_call_arguments(a, p.view, fence)
			if len(arguments) > 0 && atomic_order_of(a, p.view, arguments[0]) == .Seq_Cst { return true }
		}
		entity, _ := atomic_callee(a, p.view, placed.call)
		target := atomic_callee_procedure(a, entity)
		if target != 0 && atomic_reaches_fence(a, target, .Seq_Cst) { return true }
	}
	return false
}

atomic_first :: proc(a: ^Atomics, site: ^Site, call: Site) {
	if site^ == {} || atomic_before(a, call, site^) { site^ = call }
}

atomic_sized :: proc(a: ^Atomics, site: ^Site, call: Site, largest: bool) {
	if site^ == {} {
		site^ = call
		return
	}
	size, other := atomic_call_size(a, atomic_call_at(a, call)), atomic_call_size(a, atomic_call_at(a, site^))
	if largest && size > other || !largest && size < other || size == other && atomic_before(a, call, site^) { site^ = call }
}
