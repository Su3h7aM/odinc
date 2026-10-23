package analysis

import "base:runtime"
import "core:fmt"
import "oc:check"
import "oc:syntax"

atomic_access_enabled :: proc(ast: ^syntax.Ast) -> bool {
	return .Atomic_Access in ast.vet
}

atomic_encloses :: proc(outer, inner: []Atomic_Arm) -> bool {
	if len(outer) > len(inner) { return false }
	for arm, index in outer {
		if arm != inner[index] { return false }
	}
	return true
}

atomic_synchronized :: proc(syncs: []Atomic_Sync, ast: ^syntax.Ast, access: Atomic_At, write: bool) -> bool {
	position := ast.nodes[access.node].start
	for acquiring in syncs {
		if acquiring.deferred || (write && acquiring.shared) || !atomic_encloses(acquiring.arms, access.arms) { continue }
		at := ast.nodes[acquiring.call].start
		undone := false
		if at < position && atomic_acquires(acquiring.order) {
			for release in syncs {
				time := ast.nodes[release.call].start
				undone ||=
					!release.deferred &&
					atomic_encloses(release.arms, access.arms) &&
					at < time &&
					time < position &&
					atomic_releases(release.order) &&
					atomic_may_be_same_object(acquiring.object, release.object)
			}
		} else if write && position < at && atomic_releases(acquiring.order) {
			for lock in syncs {
				time := ast.nodes[lock.call].start
				undone ||=
					!lock.deferred && position < time && time < at && atomic_acquires(lock.order) && atomic_may_be_same_object(acquiring.object, lock.object)
			}
		} else {
			continue
		}
		if !undone { return true }
	}
	return false
}

// The synchronization a procedure without `@(synchronizes)` performs on what it is given or what is global.
atomic_infer :: proc(a: ^Atomics, inferring: []bool, id: Procedure_Id) -> runtime.Allocator_Error {
	checked := a.program.procedure_list[a.run.procedures[id].checked_index]
	entity_data, has_data := a.program.entities[checked.entity].data.(check.Procedure_Data)
	if a.inferred[id] || checked.body.node == 0 || (has_data && entity_data.atomic.synchronizes != .Relaxed) { return nil }
	a.inferred[id] = true

	exits := make([dynamic]Atomic_Exit, a.allocator)
	scan := atomic_scan_init(a, id)
	scan.exits = &exits
	scan.inferring = inferring
	atomic_scan(&scan, checked.body.node, false) or_return
	statements := syntax.node_list(scan.ast, syntax.node_payload(scan.ast, checked.body.node, syntax.Block_Stmt).stmts)
	if len(statements) == 0 || scan.ast.nodes[statements[len(statements) - 1]].kind != .Return_Stmt {
		append(&exits, Atomic_Exit{len(scan.syncs), nil}) or_return
	}

	syncs := scan.syncs[:]
	effects := make([dynamic]Atomic_Effect, a.allocator)
	for sync, index in syncs {
		seen := false
		for earlier in syncs[:index] { seen ||= atomic_same_object(earlier.object, sync.object) }
		if seen { continue }

		effect := Atomic_Effect {
			param  = -1,
			object = sync.object,
			order  = .Relaxed,
			shared = true,
		}
		releases, acquired := false, false
		for later in syncs[index:] {
			if !atomic_same_object(later.object, sync.object) { continue }
			if !acquired && atomic_releases(later.order) {
				releases = true
				effect.shared &&= later.shared
			}
			acquired ||= !later.deferred && atomic_acquires(later.order)
		}
		acquires := false
		for exit in exits {
			for acquiring, j in syncs[:exit.syncs] {
				if acquiring.deferred ||
				   !atomic_acquires(acquiring.order) ||
				   !atomic_same_object(acquiring.object, sync.object) ||
				   !atomic_encloses(acquiring.arms, exit.arms) {
					continue
				}
				released := false
				for release, k in syncs[:exit.syncs] {
					released ||=
						(release.deferred || (k > j && atomic_encloses(release.arms, exit.arms))) &&
						atomic_releases(release.order) &&
						atomic_may_be_same_object(release.object, sync.object)
				}
				if !released {
					acquires = true
					effect.shared &&= acquiring.shared
				}
			}
		}
		switch {
		case acquires && releases:
			effect.order = .Acq_Rel
		case acquires:
			effect.order = .Acquire
		case releases:
			effect.order = .Release
		case:
			continue
		}

		root := sync.object.root
		if root != 0 {
			variable := &a.program.entities[root]
			if .Parameter in variable.flags {
				for parameter, k in checked.parameters {
					if parameter == root { effect.param = i32(k) }
				}
				if effect.param < 0 { continue }
			} else if data, ok := variable.data.(check.Variable_Data); !ok || data.storage == .Local {
				continue
			}
		}
		append(&effects, effect) or_return
	}
	a.effects[id] = effects[:]
	return nil
}

atomic_vet_access :: proc(a: ^Atomics) -> runtime.Allocator_Error {
	vetted := false
	for file in a.program.files { vetted ||= file.ast != nil && atomic_access_enabled(file.ast) }
	if !vetted || len(a.uses) == 0 { return nil }

	inferring := make([]bool, len(a.procedures), a.allocator) or_return
	queue := make([dynamic]Procedure_Id, a.allocator)
	for id in 1 ..< Procedure_Id(len(a.procedures)) {
		entity := a.program.procedure_list[a.run.procedures[id].checked_index].entity
		data, ok := a.program.entities[entity].data.(check.Procedure_Data)
		if !ok || data.atomic.synchronizes == .Relaxed { continue }
		for caller in adjacent(a.graph.referrers, id) {
			if !inferring[caller] {
				inferring[caller] = true
				append(&queue, caller) or_return
			}
		}
	}
	for index := 0; index < len(queue); index += 1 {
		for caller in adjacent(a.graph.referrers, queue[index]) {
			if !inferring[caller] {
				inferring[caller] = true
				append(&queue, caller) or_return
			}
		}
	}
	for flagged, id in inferring {
		if flagged { atomic_infer(a, inferring, Procedure_Id(id)) or_return }
	}

	for id in 1 ..< Procedure_Id(len(a.procedures)) {
		checked := a.program.procedure_list[a.run.procedures[id].checked_index]
		ast := atomic_ast(a, checked.view)
		if checked.body.node == 0 || .Atomic not_in ast.analysis || !atomic_access_enabled(ast) { continue }
		scan := atomic_scan_init(a, id)
		atomic_scan(&scan, checked.body.node, false) or_return
		for access in scan.writes {
			atomic_plain_access(a, &scan, checked.view, access, true) or_return
		}
		for access in scan.reads {
			atomic_plain_access(a, &scan, checked.view, access, false) or_return
		}
	}
	return nil
}

atomic_plain_access :: proc(a: ^Atomics, scan: ^Atomic_Scan, view: check.View_Id, access: Atomic_At, write: bool) -> runtime.Allocator_Error {
	if atomic_synchronized(scan.syncs[:], scan.ast, access, write) { return nil }
	site := Site{view, access.node}
	location, _ := atomic_location(a, view, access.node)
	text := atomic_text(a, site)
	first := atomic_position(a, a.uses[location].first)
	reason: string
	if write {
		reason = fmt.aprintf(
			"'%s' is written plainly, but it is accessed atomically, e.g. at %s\n\tSuggestion: Write it with 'atomic_store_explicit(&%s, ..., .Relaxed)', or take a lock around it",
			text,
			first,
			text,
			allocator = a.allocator,
		)
	} else {
		reason = fmt.aprintf(
			"'%s' is read plainly, but it is accessed atomically, e.g. at %s\n\tSuggestion: Read it with 'atomic_load_explicit(&%s, .Relaxed)', or take a lock around it",
			text,
			first,
			text,
			allocator = a.allocator,
		)
	}
	_, err := append(&a.run.diagnostics, Diagnostic{.Error, atomic_span(a, site), reason})
	return err
}
