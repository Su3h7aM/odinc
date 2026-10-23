package analysis

import "base:runtime"
import "core:fmt"
import "core:slice"
import "oc:check"
import "oc:syntax"

atomics_run :: proc(run: ^Run, graph: ^Call_Graph) -> runtime.Allocator_Error {
	count := len(run.procedures)
	allocator := run.allocator
	a := Atomics {
		run       = run,
		graph     = graph,
		program   = run.program,
		allocator = allocator,
	}
	a.procedures = make([]Atomic_Procedure, count, allocator) or_return
	a.effects = make([][]Atomic_Effect, count, allocator) or_return
	a.inferred = make([]bool, count, allocator) or_return
	a.stamp = make([]u32, count, allocator) or_return
	a.uses = make(map[Location]Atomic_Uses, allocator)
	a.call_index = make(map[Site]int, allocator)
	a.locations = make([dynamic]Location, allocator)
	a.reports = make([dynamic]Atomic_Report, allocator)
	a.calls = make([dynamic]Atomic_Call, allocator)
	a.created = make([dynamic]Procedure_Id, allocator)
	a.queue = make([dynamic]Procedure_Id, allocator)
	atomic_collect(&a) or_return
	atomic_record_fences(&a)

	covered_acquire := make([]bool, count, allocator) or_return
	covered_release := make([]bool, count, allocator) or_return
	for id in a.created {
		p := &a.procedures[id]
		for placed in p.places {
			entity, _ := atomic_callee(&a, p.view, placed.call)
			target := atomic_callee_procedure(&a, entity)
			if target == 0 { continue }
			if atomic_fenced(&a, p, p.acquires[:], placed.call, true) { atomic_cover(&a, covered_acquire, target) }
			if atomic_fenced(&a, p, p.releases[:], placed.call, false) { atomic_cover(&a, covered_release, target) }
		}
	}

	write_sites := make([dynamic]Atomic_Site, allocator)
	wake_sites := make([dynamic]Atomic_Site, allocator)
	relaxed_reads := make([dynamic]Atomic_Site, allocator)
	relaxed_writes := make([dynamic]Atomic_Site, allocator)
	accesses := make([dynamic]Atomic_Access, allocator)
	operated := make(map[Site]bool, allocator)
	locals := make(map[check.Entity_Id]Atomic_Local, allocator)
	volatiles := make(map[Location]Site, allocator)
	volatile_order := make([dynamic]Location, allocator)

	for call in a.calls {
		_, fence := atomic_builtin(call.kind)
		if fence { continue }
		view := call.call.view
		pointer := atomic_call_pointer(&a, call)
		if pointer == 0 { continue }
		address := atomic_address_of(&a, view, pointer)
		if address == 0 { continue }
		operated[Site{view, address}] = true
		target := syntax.node_payload(atomic_ast(&a, view), address, syntax.Unary_Expr).expr
		if call.kind == .Volatile_Load || call.kind == .Volatile_Store {
			if location, ok := atomic_location(&a, view, target); ok {
				site, seen := volatiles[location]
				if !seen { append(&volatile_order, location) or_return }
				atomic_first(&a, &site, call.call)
				volatiles[location] = site
			}
			continue
		}
		if call.futex == .None {
			if local := atomic_local(&a, view, target); local != 0 {
				entry, seen := locals[local]
				if !seen { entry.procedure = call.procedure }
				entry.count += 1
				atomic_first(&a, &entry.first, call.call)
				locals[local] = entry
			}
		}
		location, located := atomic_location(&a, view, target)
		if !located { continue }
		operation, wake := atomic_operation(&a, call)
		if wake {
			append(&wake_sites, Atomic_Site{location, call.call, call.procedure}) or_return
			continue
		}
		p := &a.procedures[call.procedure]
		uses, known := a.uses[location]
		if !known {
			if location.entity !=
			   0 { uses.escaped = .Foreign in a.program.entities[location.entity].flags || .Export in a.program.entities[location.entity].flags }
			append(&a.locations, location) or_return
		}
		reported := operation.explicit && operation.order != .Seq_Cst && atomic_analyzed(&a, call.call)
		if call.futex == .None && operation.reads != operation.writes {
			append(&accesses, Atomic_Access{location, call.call, call.procedure, operation.writes, operation.order == .Seq_Cst}) or_return
		}
		atomic_first(&a, &uses.first, call.call)
		atomic_sized(&a, &uses.smallest, call.call, false)
		atomic_sized(&a, &uses.largest, call.call, true)
		if operation.reads && !operation.writes { atomic_first(&a, &uses.load, call.call) }
		if operation.writes && !operation.reads { atomic_first(&a, &uses.store, call.call) }
		if operation.reads {
			acquires := atomic_acquires(operation.order) || atomic_acquires(operation.failure)
			if !acquires && p.ready { acquires = atomic_fenced(&a, p, p.acquires[:], call.call.node, true) }
			acquires ||= covered_acquire[call.procedure]
			uses.acquires ||= acquires
			if !acquires { append(&relaxed_reads, Atomic_Site{location, call.call, call.procedure}) or_return }
			if reported && atomic_acquires(operation.order) { atomic_first(&a, &uses.asks_acquire, call.call) }
		}
		if operation.writes {
			append(&write_sites, Atomic_Site{location, call.call, call.procedure}) or_return
			releases := atomic_releases(operation.order)
			if !releases && p.ready { releases = atomic_fenced(&a, p, p.releases[:], call.call.node, false) }
			releases ||= covered_release[call.procedure]
			uses.releases ||= releases
			if !releases { append(&relaxed_writes, Atomic_Site{location, call.call, call.procedure}) or_return }
			if reported && atomic_releases(operation.order) { atomic_first(&a, &uses.asks_release, call.call) }
		}
		a.uses[location] = uses
	}

	for event in run.events[1:] {
		view := event.expression.view
		ast := atomic_ast(&a, view)
		if event.expression.node == 0 || ast.nodes[event.expression.node].kind != .Unary_Expr { continue }
		unary := syntax.node_payload(ast, event.expression.node, syntax.Unary_Expr)
		if unary.op.kind != .And || operated[event.expression] { continue }
		if location, ok := atomic_location(&a, view, unary.expr); ok {
			if uses, known := &a.uses[location]; known { uses.escaped = true }
		}
	}

	atomic_report_ordering(
		&a,
		write_sites[:],
		wake_sites[:],
		relaxed_reads[:],
		relaxed_writes[:],
		accesses[:],
		&locals,
		volatiles,
		volatile_order[:],
	) or_return
	return atomic_vet_access(&a)
}

atomic_report_ordering :: proc(
	a: ^Atomics,
	write_sites, wake_sites, relaxed_reads, relaxed_writes: []Atomic_Site,
	accesses: []Atomic_Access,
	locals: ^map[check.Entity_Id]Atomic_Local,
	volatiles: map[Location]Site,
	volatile_order: []Location,
) -> runtime.Allocator_Error {
	for location in a.locations {
		uses := a.uses[location]
		if atomic_call_size(a, atomic_call_at(a, uses.smallest)) != atomic_call_size(a, atomic_call_at(a, uses.largest)) && atomic_analyzed(a, uses.largest) {
			append(&a.reports, Atomic_Report{.Mixed_Size, uses.largest, uses.smallest}) or_return
		}
		if uses.escaped { continue }
		if location.entity != 0 {
			if data, ok := a.program.entities[location.entity].data.(check.Variable_Data); ok && data.storage == .Thread_Local {
				if atomic_analyzed(a, uses.first) { append(&a.reports, Atomic_Report{.Thread_Local, uses.first, {}}) or_return }
				continue
			}
		}
		if uses.asks_release != {} && uses.load != {} && !uses.acquires && !atomic_fence_called(a, relaxed_reads, location, true) {
			append(&a.reports, Atomic_Report{.Release, uses.asks_release, uses.load}) or_return
		} else if uses.asks_acquire != {} && uses.store != {} && !uses.releases && !atomic_fence_called(a, relaxed_writes, location, false) {
			append(&a.reports, Atomic_Report{.Acquire, uses.asks_acquire, uses.store}) or_return
		}
	}

	for call in a.calls {
		if !atomic_is_weak(call.kind) || !atomic_analyzed(a, call.call) { continue }
		discards := !call.tuple
		if !discards {
			if place := atomic_find_place(&a.procedures[call.procedure], call.call.node); place != nil { discards = place.discards }
		}
		if discards { append(&a.reports, Atomic_Report{.Weak_Ignored, call.call, {}}) or_return }
	}

	for wake in wake_sites {
		p := &a.procedures[wake.procedure]
		if !p.ready || !atomic_analyzed(a, wake.call) { continue }
		written := false
		after: Site
		for write in write_sites {
			if write.location != wake.location || write.procedure != wake.procedure { continue }
			if atomic_may_precede(a, p, write.call.node, wake.call.node) {
				written = true
			} else if atomic_may_precede(a, p, wake.call.node, write.call.node) {
				atomic_first(a, &after, write.call)
			}
		}
		if written || after == {} { continue }
		reached := make([]bool, len(a.procedures), context.temp_allocator) or_return
		for placed in p.places {
			entity, _ := atomic_callee(a, p.view, placed.call)
			target := atomic_callee_procedure(a, entity)
			if target != 0 && atomic_may_precede(a, p, placed.call, wake.call.node) { atomic_cover(a, reached, target) }
		}
		for write in write_sites { written ||= write.location == wake.location && reached[write.procedure] }
		if !written { append(&a.reports, Atomic_Report{.Wake_Early, wake.call, after}) or_return }
	}

	walked := make([]bool, len(a.procedures), context.temp_allocator) or_return
	for _, local in locals {
		if walked[local.procedure] { continue }
		walked[local.procedure] = true
		scan := atomic_scan_init(a, local.procedure)
		scan.locals = locals
		atomic_scan(&scan, a.program.procedure_list[a.run.procedures[local.procedure].checked_index].body.node, false) or_return
	}
	for _, local in locals {
		if local.addressed == local.count && atomic_analyzed(a, local.first) { append(&a.reports, Atomic_Report{.Local, local.first, {}}) or_return }
	}

	for location in volatile_order {
		site := volatiles[location]
		if uses, known := a.uses[location]; known && atomic_analyzed(a, site) { append(&a.reports, Atomic_Report{.Volatile, site, uses.first}) or_return }
	}

	atomic_store_loads(a, accesses) or_return
	slice.sort_by_with_data(a.reports[:], proc(x, y: Atomic_Report, data: rawptr) -> bool {
			a := cast(^Atomics)data
			if !atomic_same_place(a, x.site, y.site) { return atomic_before(a, x.site, y.site) }
			return x.kind < y.kind
		}, a)
	for report, index in a.reports {
		if index > 0 && a.reports[index - 1].kind == report.kind && atomic_same_place(a, a.reports[index - 1].site, report.site) { continue }
		atomic_emit(a, report) or_return
	}
	return nil
}

// Each store followed by a load of something else within a procedure, which a reverse pair elsewhere makes a problem
// unless `.Seq_Cst` orders both sides. Locations are compared by source position, not by address.
atomic_store_loads :: proc(a: ^Atomics, accesses: []Atomic_Access) -> runtime.Allocator_Error {
	slice.sort_by_with_data(accesses, proc(x, y: Atomic_Access, data: rawptr) -> bool {
			a := cast(^Atomics)data
			if x.procedure != y.procedure { return x.procedure < y.procedure }
			return atomic_before(a, x.call, y.call)
		}, a)
	pairs := make([dynamic]AtomicStoreLoad, context.temp_allocator)
	for &store, index in accesses {
		if !store.store { continue }
		for next := index + 1; next < len(accesses) && accesses[next].procedure == store.procedure; next += 1 {
			load := &accesses[next]
			if !load.store && load.location != store.location { append(&pairs, AtomicStoreLoad{&store, load}) or_return }
		}
	}
	slice.sort_by_with_data(pairs[:], proc(x, y: AtomicStoreLoad, data: rawptr) -> bool { return atomic_pair_compare(cast(^Atomics)data, x, y) < 0 }, a)
	for start := 0; start < len(pairs); {
		finish := start
		for finish < len(pairs) && atomic_pair_compare(a, pairs[finish], pairs[start]) == 0 { finish += 1 }
		group := pairs[start:finish]
		start = finish
		first := group[0]
		if atomic_location_less(a, first.load.location, first.store.location) { continue }
		reverse_store := Atomic_Access {
			location = first.load.location,
		}
		reverse_load := Atomic_Access {
			location = first.store.location,
		}
		reverse := AtomicStoreLoad{&reverse_store, &reverse_load}
		low, high := 0, len(pairs)
		for low < high {
			middle := low + (high - low) / 2
			if atomic_pair_compare(a, pairs[middle], reverse) < 0 { low = middle + 1 } else { high = middle }
		}
		end := low
		for end < len(pairs) && atomic_pair_compare(a, pairs[end], reverse) == 0 { end += 1 }
		if low == end { continue }
		x_unordered, y_unordered, x_first, y_first: Site
		for pair in group {
			p := atomic_procedure(a, pair.store.procedure)
			if !atomic_may_precede(a, p, pair.store.call.node, pair.load.call.node) { continue }
			atomic_first(a, &x_first, pair.store.call)
			if !atomic_seq_cst_ordered(a, pair) { atomic_first(a, &x_unordered, pair.store.call) }
		}
		for pair in pairs[low:end] {
			p := atomic_procedure(a, pair.store.procedure)
			if !atomic_may_precede(a, p, pair.store.call.node, pair.load.call.node) { continue }
			atomic_first(a, &y_first, pair.store.call)
			if !atomic_seq_cst_ordered(a, pair) { atomic_first(a, &y_unordered, pair.store.call) }
		}
		if x_first == {} || y_first == {} { continue }
		site, other := x_unordered, y_first
		if site == {} || y_unordered != {} && atomic_before(a, y_unordered, site) { site, other = y_unordered, x_first }
		if site != {} && atomic_analyzed(a, site) { append(&a.reports, Atomic_Report{.Store_Load, site, other}) or_return }
	}
	return nil
}

atomic_pair_compare :: proc(a: ^Atomics, x, y: AtomicStoreLoad) -> int {
	if x.store.location != y.store.location { return -1 if atomic_location_less(a, x.store.location, y.store.location) else 1 }
	if x.load.location != y.load.location { return -1 if atomic_location_less(a, x.load.location, y.load.location) else 1 }
	return 0
}

atomic_warn :: proc(a: ^Atomics, span: check.Source_Span, format: string, arguments: ..any) -> runtime.Allocator_Error {
	reason := fmt.aprintf(format, ..arguments, allocator = a.allocator)
	_, err := append(&a.run.diagnostics, Diagnostic{.Warning, span, reason})
	return err
}

atomic_emit :: proc(a: ^Atomics, report: Atomic_Report) -> runtime.Allocator_Error {
	call := atomic_call_at(a, report.site)
	view := report.site.view
	ast := atomic_ast(a, view)
	span := atomic_span(a, report.site)
	#partial switch report.kind {
	case .Weak_Ignored:
		name := atomic_text(a, {view, syntax.node_payload(ast, report.site.node, syntax.Call_Expr).expr})
		return atomic_warn(
			a,
			span,
			"'%s' may fail even when the value matches, so only its second result says whether it stored\n\tSuggestion: Use its second result, or the strong form when it is not retried",
			name,
		)
	case .Thread_Local:
		location, _ := atomic_location(a, view, atomic_call_target(a, call))
		return atomic_warn(
			a,
			span,
			"'%s' is @(thread_local) and its address is not taken, so only its own thread can access it, and the atomics on it order nothing\n\tSuggestion: If it is meant to be shared between threads, it cannot be @(thread_local)",
			a.program.entities[location.entity].name,
		)
	case .Local:
		name := a.program.entities[atomic_local(a, view, atomic_call_target(a, call))].name
		return atomic_warn(
			a,
			span,
			"The address of '%s' is only taken by atomic operations, so nothing else can access it, and they order nothing\n\tSuggestion: To keep its accesses from being optimized away, use 'volatile_load' and 'volatile_store', which order nothing between threads\n\t            If it is meant to be shared, it may be a copy of what is",
			name,
		)
	}
	text := atomic_text(a, {view, atomic_call_target(a, call)})
	other_call := atomic_call_at(a, report.other)
	other := atomic_position(a, report.other)
	other_procedure := &a.procedures[other_call.procedure]
	signal_note := "\n\t            'atomic_signal_fence' only orders against a signal handler on the same thread, unlike 'atomic_thread_fence'"
	#partial switch report.kind {
	case .Release:
		suggestion := fmt.aprintf("\tSuggestion: Load it with .Acquire, e.g. at %s, or write it with .Relaxed", other, allocator = a.allocator)
		if other_call.futex == .Wait {
			suggestion = fmt.aprintf(
				"\tSuggestion: A futex wait does not acquire, so load it with .Acquire after the wait at %s, or write it with .Relaxed",
				other,
				allocator = a.allocator,
			)
		}
		if other_procedure.ready && atomic_fenced(a, other_procedure, other_procedure.signal_acquires[:], report.other.node, true) {
			suggestion = fmt.aprintf("%s%s", suggestion, signal_note, allocator = a.allocator)
		}
		return atomic_warn(
			a,
			span,
			"'%s' is written with release ordering, but it is only loaded with relaxed ordering, so the release orders nothing\n%s",
			text,
			suggestion,
		)
	case .Acquire:
		suggestion := fmt.aprintf("\tSuggestion: Store it with .Release, e.g. at %s, or read it with .Relaxed", other, allocator = a.allocator)
		if other_procedure.ready && atomic_fenced(a, other_procedure, other_procedure.signal_releases[:], report.other.node, false) {
			suggestion = fmt.aprintf("%s%s", suggestion, signal_note, allocator = a.allocator)
		}
		return atomic_warn(
			a,
			span,
			"'%s' is read with acquire ordering, but it is only stored with relaxed ordering, so the acquire orders nothing\n%s",
			text,
			suggestion,
		)
	case .Wake_Early:
		return atomic_warn(
			a,
			span,
			"'%s' is woken before it is written, so what waits on it may see it unchanged and sleep again\n\tSuggestion: Wake it after the write at %s",
			text,
			other,
		)
	case .Mixed_Size:
		pointer := Site{view, atomic_call_pointer(a, call)}
		return atomic_warn(
			a,
			atomic_span(a, pointer),
			"'%s' is accessed atomically as %d bytes, but as %d bytes at %s, which C11 leaves undefined\n\tSuggestion: Access it atomically with one size everywhere",
			text,
			atomic_call_size(a, call),
			atomic_call_size(a, other_call),
			other,
		)
	case .Store_Load:
		other_text := atomic_text(a, {report.other.view, atomic_call_target(a, other_call)})
		address := Site{view, atomic_address_of(a, view, atomic_call_pointer(a, call))}
		return atomic_warn(
			a,
			atomic_span(a, address),
			"'%s' is stored and then '%s' loaded, while the reverse is done at %s, so both loads may read what was there before\n\tSuggestion: Use .Seq_Cst for these stores and loads, or 'atomic_thread_fence(.Seq_Cst)' between each store and the load after it",
			text,
			other_text,
			other,
		)
	case .Volatile:
		name := atomic_text(a, {view, syntax.node_payload(ast, report.site.node, syntax.Call_Expr).expr})
		replacement := "atomic_load_explicit" if len(atomic_call_arguments(a, view, report.site.node)) == 1 else "atomic_store_explicit"
		return atomic_warn(
			a,
			span,
			"'%s' is accessed with '%s', which is not atomic, but it is accessed atomically, e.g. at %s\n\tSuggestion: Use '%s' instead, with .Relaxed ordering or stronger",
			text,
			name,
			other,
			replacement,
		)
	}
	return nil
}
