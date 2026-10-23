package analysis

import "base:runtime"
import "core:slice"
import "oc:check"
import "oc:syntax"
import "oc:types"

Atomic_Scan :: struct {
	a:         ^Atomics,
	view:      check.View_Id,
	ast:       ^syntax.Ast,
	reads:     [dynamic]Atomic_At,
	writes:    [dynamic]Atomic_At,
	syncs:     [dynamic]Atomic_Sync,
	arms:      [dynamic]Atomic_Arm,
	place:     Atomic_Place,
	places:    ^[dynamic]Placed_Call,
	locals:    ^map[check.Entity_Id]Atomic_Local,
	local_of:  Procedure_Id,
	exits:     ^[dynamic]Atomic_Exit,
	inferring: []bool,
}

atomic_scan_init :: proc(a: ^Atomics, procedure: Procedure_Id) -> Atomic_Scan {
	view := a.program.procedure_list[a.run.procedures[procedure].checked_index].view
	return Atomic_Scan {
		a = a,
		view = view,
		ast = atomic_ast(a, view),
		reads = make([dynamic]Atomic_At, a.allocator),
		writes = make([dynamic]Atomic_At, a.allocator),
		syncs = make([dynamic]Atomic_Sync, a.allocator),
		arms = make([dynamic]Atomic_Arm, a.allocator),
		local_of = procedure,
	}
}

atomic_arms :: proc(s: ^Atomic_Scan) -> []Atomic_Arm {
	return slice.clone(s.arms[:], s.a.allocator)
}

atomic_address_taken :: proc(s: ^Atomic_Scan, node: syntax.Node_Index) {
	if s.locals == nil { return }
	local := atomic_local(s.a, s.view, node)
	if local == 0 { return }
	if found, ok := &s.locals[local]; ok { found.addressed += 1 }
}

atomic_discard :: proc(s: ^Atomic_Scan, expr: syntax.Node_Index) {
	node := atomic_unparen(s.ast, expr)
	if s.places == nil || s.ast.nodes[node].kind != .Call_Expr { return }
	for &placed in s.places^ {
		if placed.call == node { placed.place.discards = true }
	}
}

atomic_add_syncs :: proc(s: ^Atomic_Scan, call: syntax.Node_Index, callee, target: check.Entity_Id, deferred: bool) -> runtime.Allocator_Error {
	a := s.a
	data, ok := atomic_procedure_data(a, target)
	if !ok { return nil }
	sync := Atomic_Sync {
		call     = call,
		deferred = deferred,
	}
	if data.atomic.synchronizes != .Relaxed {
		sync.arms = atomic_arms(s)
		sync.order = data.atomic.synchronizes
		sync.shared = data.atomic.synchronizes_shared
		if argument := atomic_call_argument(a, s.view, call, callee, 0); argument != 0 { sync.object = atomic_object(a, s.view, argument) }
		append(&s.syncs, sync) or_return
		return nil
	}
	procedure := atomic_callee_procedure(a, target)
	if procedure == 0 { return nil }
	if s.inferring != nil && s.inferring[procedure] { atomic_infer(a, s.inferring, procedure) or_return }
	for effect in a.effects[procedure] {
		sync.arms = atomic_arms(s)
		sync.order = effect.order
		sync.shared = effect.shared
		sync.object = effect.object
		if effect.param >= 0 {
			sync.object = {}
			if argument := atomic_call_argument(a, s.view, call, callee, int(effect.param)); argument != 0 {
				object := atomic_object(a, s.view, argument)
				if object.root != 0 { sync.object = Atomic_Object{object.root, slice_join(a, {object.path, effect.object.path})} }
			}
		}
		append(&s.syncs, sync) or_return
	}
	return nil
}

atomic_scan_arm :: proc(s: ^Atomic_Scan, branch: syntax.Node_Index, arm: i32, node: syntax.Node_Index) -> runtime.Allocator_Error {
	append(&s.arms, Atomic_Arm{branch, arm}) or_return
	atomic_scan(s, node, false) or_return
	pop(&s.arms)
	return nil
}

atomic_scan_list :: proc(s: ^Atomic_Scan, nodes: syntax.Node_Range, addr := false) -> runtime.Allocator_Error {
	for node in syntax.node_list(s.ast, nodes) { atomic_scan(s, node, addr) or_return }
	return nil
}

atomic_scan_clauses :: proc(s: ^Atomic_Scan, node, body: syntax.Node_Index) -> runtime.Allocator_Error {
	if body == 0 || s.ast.nodes[body].kind != .Block_Stmt {
		return atomic_scan(s, body, false)
	}
	clauses := syntax.node_list(s.ast, syntax.node_payload(s.ast, body, syntax.Block_Stmt).stmts)
	falls := false
	for clause in clauses {
		if s.ast.nodes[clause].kind != .Case_Clause { continue }
		statements := syntax.node_list(s.ast, syntax.node_payload(s.ast, clause, syntax.Case_Clause).body)
		if len(statements) == 0 { continue }
		last := statements[len(statements) - 1]
		if s.ast.nodes[last].kind == .Branch_Stmt && syntax.node_payload(s.ast, last, syntax.Branch_Stmt).token.kind == .Fallthrough { falls = true }
	}
	for clause, index in clauses {
		if falls {
			atomic_scan(s, clause, false) or_return
		} else {
			atomic_scan_arm(s, node, i32(index), clause) or_return
		}
	}
	return nil
}

// The plain reads within a statement or an expression, of which only the address is used when `addr`.
atomic_scan :: proc(s: ^Atomic_Scan, node: syntax.Node_Index, addr: bool) -> runtime.Allocator_Error {
	if node == 0 { return nil }
	a := s.a
	ast := s.ast
	info := atomic_info(a, s.view, node)
	if info.mode == .Constant || info.mode == .Type || info.state == .Inactive || info.state == .Invalid { return nil }
	place := s.place
	defer s.place = place
	kind := ast.nodes[node].kind
	#partial switch kind {
	case .Ident, .Selector_Expr, .Index_Expr:
		if !addr {
			if location, ok := atomic_location(a, s.view, node); ok && location in a.uses {
				append(&s.reads, Atomic_At{node, atomic_arms(s)}) or_return
			}
		}
	case .Call_Expr:
		if s.places != nil {
			call_place := s.place
			call_place.arms = atomic_arms(s)
			append(s.places, Placed_Call{node, call_place}) or_return
		}
	case .For_Stmt, .Range_Stmt, .Unroll_Range_Stmt:
		if s.place.loop == 0 { s.place.loop = node }
	case .Defer_Stmt:
		s.place.deferred = true
	}

	#partial switch payload in ast.nodes[node].payload {
	case syntax.Paren_Expr:
		atomic_scan(s, payload.expr, addr) or_return
	case syntax.Unary_Expr:
		if payload.op.kind == .And { atomic_address_taken(s, payload.expr) }
		atomic_scan(s, payload.expr, payload.op.kind == .And) or_return
	case syntax.Binary_Expr:
		atomic_scan(s, payload.left, false) or_return
		atomic_scan(s, payload.right, false) or_return
	case syntax.Selector_Expr:
		if check.plan(a.program, info.plan) == nil && atomic_variable_entity(a, info.entity) { break }
		if atomic_is_pointer(a, atomic_info(a, s.view, payload.expr).type) {
			atomic_scan(s, payload.expr, false) or_return
		} else {
			swizzle := false
			if plan := check.plan(a.program, info.plan); plan != nil {
				_, swizzle = plan^.(check.Swizzle_Plan)
			}
			atomic_scan(s, payload.expr, addr || !swizzle) or_return
		}
	case syntax.Index_Expr:
		base := atomic_info(a, s.view, payload.expr).type
		kind := types_kind(a, base)
		atomic_scan(
			s,
			payload.expr,
			kind == .Array || kind == .Enumerated_Array || kind == .Fixed_Capacity_Array || kind == .Matrix || kind == .Struct,
		) or_return
		atomic_scan(s, payload.index, false) or_return
	case syntax.Matrix_Index_Expr:
		atomic_scan(s, payload.expr, true) or_return
		atomic_scan(s, payload.row_index, false) or_return
		atomic_scan(s, payload.column_index, false) or_return
	case syntax.Deref_Expr:
		atomic_scan(s, payload.expr, false) or_return
	case syntax.Slice_Expr:
		like := atomic_array_like(a, atomic_info(a, s.view, payload.expr).type)
		if like { atomic_address_taken(s, payload.expr) }
		atomic_scan(s, payload.expr, like) or_return
		atomic_scan(s, payload.low, false) or_return
		atomic_scan(s, payload.high, false) or_return
	case syntax.Call_Expr:
		callee := atomic_unparen(ast, payload.expr)
		callee_info := atomic_info(a, s.view, callee)
		if callee_info.mode != .Type && callee_info.mode != .Builtin {
			entity, plan := atomic_callee(a, s.view, node)
			if entity != 0 {
				atomic_add_syncs(s, node, entity, entity, s.place.deferred) or_return
				if plan.deferred != 0 && atomic_deferred_in(a, entity) { atomic_add_syncs(s, node, entity, plan.deferred, true) or_return }
			}
			atomic_scan(s, payload.expr, false) or_return
		}
		atomic_scan_list(s, payload.args) or_return
	case syntax.Selector_Call_Expr:
		atomic_scan(s, payload.call, false) or_return
	case syntax.Ellipsis:
		atomic_scan(s, payload.expr, false) or_return
	case syntax.Comp_Lit:
		atomic_scan_list(s, payload.elems) or_return
	case syntax.Field_Value:
		atomic_scan(s, payload.value, false) or_return
	case syntax.Ternary_Expr:
		if kind == .Ternary_If_Expr {
			atomic_scan(s, payload.cond, false) or_return
			atomic_scan_arm(s, node, 0, payload.x) or_return
			atomic_scan_arm(s, node, 1, payload.y) or_return
		} else if constant := check.constant(a.program, atomic_info(a, s.view, payload.cond).constant); constant != nil {
			if value, ok := constant.value.(bool); ok { atomic_scan(s, payload.x if value else payload.y, false) or_return }
		}
	case syntax.Or_Else_Expr:
		atomic_scan(s, payload.x, false) or_return
		atomic_scan(s, payload.y, false) or_return
	case syntax.Or_Return_Expr:
		atomic_scan(s, payload.expr, false) or_return
		if s.exits != nil { append(s.exits, Atomic_Exit{len(s.syncs), atomic_arms(s)}) or_return }
	case syntax.Or_Branch_Expr:
		atomic_scan(s, payload.expr, false) or_return
	case syntax.Type_Assertion:
		atomic_scan(s, payload.expr, false) or_return
	case syntax.Type_Cast:
		atomic_scan(s, payload.expr, false) or_return
	case syntax.Auto_Cast:
		atomic_scan(s, payload.expr, false) or_return
	case syntax.Tag_Expr:
		atomic_scan(s, payload.expr, false) or_return
	case syntax.Expr_Stmt:
		atomic_scan(s, payload.expr, false) or_return
		atomic_discard(s, payload.expr)
	case syntax.Value_Decl:
		if payload.is_mutable {
			atomic_scan_list(s, payload.values) or_return
			values, names := syntax.node_list(ast, payload.values), syntax.node_list(ast, payload.names)
			if len(values) == 1 && len(names) == 2 && atomic_blank(a, s.view, names[1]) { atomic_discard(s, values[0]) }
		}
	case syntax.Assign_Stmt:
		atomic_scan_list(s, payload.rhs) or_return
		plain := payload.op.kind == .Eq
		left, right := syntax.node_list(ast, payload.lhs), syntax.node_list(ast, payload.rhs)
		for lhs in left {
			atomic_scan(s, lhs, plain) or_return
			if !plain { continue }
			if location, ok := atomic_location(a, s.view, lhs); ok && location in a.uses {
				append(&s.writes, Atomic_At{lhs, atomic_arms(s)}) or_return
			}
		}
		if plain && len(right) == 1 && len(left) == 2 && atomic_blank(a, s.view, left[1]) { atomic_discard(s, right[0]) }
	case syntax.Block_Stmt:
		atomic_scan_list(s, payload.stmts) or_return
	case syntax.If_Stmt:
		atomic_scan(s, payload.init, false) or_return
		atomic_scan(s, payload.cond, false) or_return
		atomic_scan_arm(s, node, 0, payload.body) or_return
		atomic_scan_arm(s, node, 1, payload.else_stmt) or_return
	case syntax.When_Stmt:
		if constant := check.constant(a.program, atomic_info(a, s.view, payload.cond).constant); constant != nil {
			if value, ok := constant.value.(bool); ok { atomic_scan(s, payload.body if value else payload.else_stmt, false) or_return }
		}
	case syntax.Return_Stmt:
		atomic_scan_list(s, payload.results) or_return
		if s.exits != nil { append(s.exits, Atomic_Exit{len(s.syncs), atomic_arms(s)}) or_return }
	case syntax.For_Stmt:
		atomic_scan(s, payload.init, false) or_return
		atomic_scan(s, payload.cond, false) or_return
		atomic_scan(s, payload.post, false) or_return
		atomic_scan(s, payload.body, false) or_return
	case syntax.Range_Stmt:
		by_ref := false
		for value in syntax.node_list(ast, payload.vals) {
			by_ref ||= ast.nodes[value].kind == .Unary_Expr && syntax.node_payload(ast, value, syntax.Unary_Expr).op.kind == .And
		}
		by_ref &&= atomic_array_like(a, atomic_info(a, s.view, payload.expr).type)
		if by_ref { atomic_address_taken(s, payload.expr) }
		atomic_scan(s, payload.expr, by_ref) or_return
		atomic_scan(s, payload.body, false) or_return
	case syntax.Unroll_Range_Stmt:
		by_ref := false
		for value in ([2]syntax.Node_Index{payload.val0, payload.val1}) {
			by_ref ||= value != 0 && ast.nodes[value].kind == .Unary_Expr && syntax.node_payload(ast, value, syntax.Unary_Expr).op.kind == .And
		}
		by_ref &&= atomic_array_like(a, atomic_info(a, s.view, payload.expr).type)
		if by_ref { atomic_address_taken(s, payload.expr) }
		atomic_scan(s, payload.expr, by_ref) or_return
		atomic_scan(s, payload.body, false) or_return
	case syntax.Switch_Stmt:
		atomic_scan(s, payload.init, false) or_return
		atomic_scan(s, payload.cond, false) or_return
		atomic_scan_clauses(s, node, payload.body) or_return
	case syntax.Type_Switch_Stmt:
		atomic_scan(s, payload.expr, false) or_return
		atomic_scan_clauses(s, node, payload.body) or_return
	case syntax.Case_Clause:
		atomic_scan_list(s, payload.list) or_return
		atomic_scan_list(s, payload.body) or_return
	case syntax.Defer_Stmt:
		atomic_scan(s, payload.stmt, false) or_return
	case syntax.Tag_Stmt:
		atomic_scan(s, payload.stmt, false) or_return
	}
	return nil
}

atomic_variable_entity :: proc(a: ^Atomics, entity: check.Entity_Id) -> bool {
	_, ok := atomic_variable(a, entity)
	return ok
}

atomic_blank :: proc(a: ^Atomics, view: check.View_Id, node: syntax.Node_Index) -> bool {
	return atomic_text(a, {view, node}) == "_"
}

types_kind :: proc(a: ^Atomics, id: types.Type_Id) -> types.Kind {
	if id == types.TYPE_NONE || id == types.TYPE_POISON { return .Invalid }
	return types.get(a.program.type_data, types.resolve_named(a.program.type_data, id)).kind
}

// Whether the callee's `deferred_in` family of attributes defers a procedure given the same arguments.
atomic_deferred_in :: proc(a: ^Atomics, callee: check.Entity_Id) -> bool {
	for attribute in a.program.entities[callee].attributes {
		switch attribute.name {
		case "deferred_in", "deferred_in_out", "deferred_in_by_ptr", "deferred_in_out_by_ptr":
			return true
		}
	}
	return false
}
