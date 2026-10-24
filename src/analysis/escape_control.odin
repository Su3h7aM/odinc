package analysis

import "base:runtime"
import "core:fmt"
import "oc:check"
import "oc:syntax"
import "oc:types"

Nil_Fact :: struct {
	entity: check.Entity_Id,
	path:   Path_Id,
	uninit: bool,
}

Nil_Use_Kind :: enum u8 {
	Deref,
	Call,
	Uninit,
}

Nil_Use :: struct {
	expression: check.Expression_Ref,
	kind:       Nil_Use_Kind,
	definite:   bool,
}

Defer_Frame :: struct {
	stmts: [dynamic]syntax.Node_Index,
}

Control_Kind :: enum u8 {
	Loop,
	Switch,
	Label,
}

Escape_State :: struct {
	reachable: bool,
	memory:    [dynamic]Value_Id,
	nils:      [dynamic]Nil_Fact,
	outers:    [dynamic]Outer_Store,
}

Control_Target :: struct {
	node:        syntax.Node_Index,
	kind:        Control_Kind,
	defer_depth: int,
	breaks:      Escape_State,
	continues:   Escape_State,
}

MAX_FACT_COUNT :: 1 << 13
MAX_STMT_VISITS :: 1 << 20

@(private = "package")
escape_too_large :: proc(escape: ^Escape) -> bool {
	escape.too_large ||= escape.live_facts + len(escape.outers) > MAX_FACT_COUNT || escape.stmt_visits > MAX_STMT_VISITS
	return escape.too_large
}

@(private = "package")
escape_reset_control :: proc(escape: ^Escape) {
	clear(&escape.nils)
	clear(&escape.nil_uses)
	clear(&escape.uninit_entities)
	clear(&escape.nil_escaped)
	clear(&escape.defers)
	clear(&escape.targets)
	clear(&escape.reported)
	clear(&escape.outers)
	clear(&escape.flows)
	escape.stmt_visits = 0
	escape.too_large = false
	escape.fallen = {}
	escape.fallen_live = false
	escape.reachable = true
}

@(private = "package")
escape_capture :: proc(escape: ^Escape) -> (state: Escape_State, err: runtime.Allocator_Error) {
	allocator := escape.allocator
	state.reachable = escape.reachable
	state.memory = make([dynamic]Value_Id, len(escape.memory), allocator) or_return
	state.nils = make([dynamic]Nil_Fact, len(escape.nils), allocator) or_return
	state.outers = make([dynamic]Outer_Store, len(escape.outers), allocator) or_return
	copy(state.memory[:], escape.memory[:])
	copy(state.nils[:], escape.nils[:])
	copy(state.outers[:], escape.outers[:])
	return
}

@(private = "package")
escape_restore :: proc(escape: ^Escape, state: Escape_State) -> runtime.Allocator_Error {
	for len(escape.memory) < len(state.memory) { append(&escape.memory, Value_Id(0)) or_return }
	for value, index in state.memory { escape.memory[index] = value }
	for index in len(state.memory) ..< len(escape.memory) { escape.memory[index] = 0 }
	escape.live_facts = 0
	for value in state.memory { escape.live_facts += len(escape_facts(escape, value)) }
	clear(&escape.nils)
	append(&escape.nils, ..state.nils[:]) or_return
	for entity in escape.nil_escaped { escape_nil_forget(escape, entity) }
	clear(&escape.outers)
	append(&escape.outers, ..state.outers[:]) or_return
	escape.reachable = state.reachable
	return nil
}

@(private = "package")
escape_union_values :: proc(escape: ^Escape, left, right: Value_Id) -> (result: Value_Id, grew: bool, err: runtime.Allocator_Error) {
	if left == right { return left, false, nil }
	if left == 0 { return right, right != 0, nil }
	if right == 0 { return left, false, nil }
	facts := make([dynamic]Value_Fact, 0, escape.allocator) or_return
	append(&facts, ..escape_facts(escape, left)) or_return
	before := len(facts)
	for fact in escape_facts(escape, right) { escape_add_fact(&facts, fact) or_return }
	grew = len(facts) != before
	if !grew { return left, false, nil }
	result = escape_value(escape, .Phi, {}, facts[:], []Value_Id{left, right}) or_return
	return
}

@(private = "file")
escape_merge_memory :: proc(escape: ^Escape, dst: ^[dynamic]Value_Id, src: []Value_Id, live: ^int) -> (changed: bool, err: runtime.Allocator_Error) {
	width := max(len(dst), len(src))
	for len(dst) < width { append(dst, Value_Id(0)) or_return }
	for index in 0 ..< width {
		right: Value_Id
		if index < len(src) { right = src[index] }
		merged, grew := escape_union_values(escape, dst[index], right) or_return
		if live != nil { live^ += len(escape_facts(escape, merged)) - len(escape_facts(escape, dst[index])) }
		dst[index] = merged
		changed |= grew
	}
	return
}

@(private = "file")
escape_nil_covered :: proc(escape: ^Escape, nils: []Nil_Fact, entity: check.Entity_Id, path: Path_Id, uninit: bool) -> bool {
	for fact in nils {
		if fact.entity == entity && fact.uninit == uninit && escape_path_has_prefix(escape, path, fact.path) { return true }
	}
	return false
}

@(private = "file")
escape_intersect_nils :: proc(left, right: []Nil_Fact, escape: ^Escape) -> (result: [dynamic]Nil_Fact, changed: bool, err: runtime.Allocator_Error) {
	result = make([dynamic]Nil_Fact, 0, escape.allocator) or_return
	if len(left) == 0 { return result, false, nil }
	for fact in left {
		if escape_nil_covered(escape, right, fact.entity, fact.path, fact.uninit) { append(&result, fact) or_return }
	}
	changed = len(result) != len(left)
	return
}

@(private = "package")
escape_join_live :: proc(escape: ^Escape, state: Escape_State) -> (changed: bool, err: runtime.Allocator_Error) {
	if !state.reachable { return false, nil }
	if !escape.reachable {
		escape_restore(escape, state) or_return
		return true, nil
	}
	changed = escape_merge_memory(escape, &escape.memory, state.memory[:], &escape.live_facts) or_return
	nils, nils_changed := escape_intersect_nils(escape.nils[:], state.nils[:], escape) or_return
	clear(&escape.nils)
	append(&escape.nils, ..nils[:]) or_return
	outers_changed := escape_merge_outers(escape, &escape.outers, state.outers[:]) or_return
	changed |= nils_changed
	changed |= outers_changed
	return
}

@(private = "package")
escape_join_state :: proc(escape: ^Escape, state: ^Escape_State) -> (changed: bool, err: runtime.Allocator_Error) {
	if !escape.reachable { return false, nil }
	if !state.reachable {
		captured := escape_capture(escape) or_return
		state^ = captured
		return true, nil
	}
	changed = escape_merge_memory(escape, &state.memory, escape.memory[:], nil) or_return
	nils, nils_changed := escape_intersect_nils(state.nils[:], escape.nils[:], escape) or_return
	state.nils = nils
	outers_changed := escape_merge_outers(escape, &state.outers, escape.outers[:]) or_return
	changed |= nils_changed
	changed |= outers_changed
	return
}

@(private = "file")
escape_push_frame :: proc(escape: ^Escape) -> runtime.Allocator_Error {
	frame := Defer_Frame {
		stmts = make([dynamic]syntax.Node_Index, 0, escape.allocator) or_return,
	}
	append(&escape.defers, frame) or_return
	return nil
}

@(private = "package")
escape_run_defers :: proc(escape: ^Escape, depth: int) -> runtime.Allocator_Error {
	for index := len(escape.defers) - 1; index >= depth; index -= 1 {
		frame := escape.defers[index]
		for stmt_index := len(frame.stmts) - 1; stmt_index >= 0; stmt_index -= 1 {
			escape_statement(escape, frame.stmts[stmt_index]) or_return
		}
	}
	return nil
}

@(private = "file")
escape_push_target :: proc(escape: ^Escape, node: syntax.Node_Index, kind: Control_Kind) -> (index: int, err: runtime.Allocator_Error) {
	target := Control_Target {
		node        = node,
		kind        = kind,
		defer_depth = len(escape.defers),
	}
	append(&escape.targets, target) or_return
	return len(escape.targets) - 1, nil
}

@(private = "package")
escape_branch :: proc(escape: ^Escape, label: syntax.Node_Index, kind: syntax.Token_Kind) -> runtime.Allocator_Error {
	labelled: syntax.Node_Index
	if label != 0 {
		info := check.expression_info(escape.run.program, escape.view, label)
		if data, ok := escape.run.program.entities[info.entity].data.(check.Label_Data); ok { labelled = data.target.node }
	}
	for index := len(escape.targets) - 1; index >= 0; index -= 1 {
		target := escape.targets[index]
		if labelled != 0 {
			if target.node != labelled { continue }
		} else if kind == .Continue {
			if target.kind != .Loop { continue }
		} else if target.kind != .Loop && target.kind != .Switch {
			continue
		}
		escape_run_defers(escape, target.defer_depth) or_return
		if kind == .Continue {
			escape_join_state(escape, &escape.targets[index].continues) or_return
		} else {
			escape_join_state(escape, &escape.targets[index].breaks) or_return
		}
		break
	}
	escape.reachable = false
	return nil
}

@(private = "package")
escape_block :: proc(escape: ^Escape, node: syntax.Node_Index, label: syntax.Node_Index, stmts: []syntax.Node_Index) -> runtime.Allocator_Error {
	escape_push_frame(escape) or_return
	target := -1
	if label != 0 { target = escape_push_target(escape, node, .Label) or_return }
	for statement in stmts {
		if !escape.reachable { break }
		escape_statement(escape, statement) or_return
	}
	if escape.reachable { escape_run_defers(escape, len(escape.defers) - 1) or_return }
	pop(&escape.defers)
	if target >= 0 {
		escape_join_live(escape, escape.targets[target].breaks) or_return
		pop(&escape.targets)
	}
	return nil
}

@(private = "package")
escape_ast :: proc(escape: ^Escape) -> ^syntax.Ast {
	return escape_view_ast(escape, escape.view)
}

@(private = "file")
escape_view_ast :: proc(escape: ^Escape, view: check.View_Id) -> ^syntax.Ast {
	program := escape.run.program
	if view == 0 || int(view) >= len(program.typed_views) { return nil }
	return program.files[program.typed_views[view].file].ast
}

@(private = "package")
escape_unparen :: proc(escape: ^Escape, node: syntax.Node_Index, view: check.View_Id = 0) -> syntax.Node_Index {
	ast := escape_view_ast(escape, escape.view if view == 0 else view)
	if ast == nil { return 0 }
	current := node
	for current != 0 && int(current) < len(ast.nodes) && ast.nodes[current].kind == .Paren_Expr {
		current = ast.nodes[current].payload.(syntax.Paren_Expr).expr
	}
	return current
}

@(private = "file")
escape_nillable :: proc(escape: ^Escape, type: types.Type_Id) -> bool {
	if type == 0 { return false }
	descriptor := escape_type(escape, type)
	#partial switch descriptor.kind {
	case .Raw_Pointer, .Pointer, .Multi_Pointer, .Procedure:
		return true
	case .Array, .Enumerated_Array, .Fixed_Capacity_Array:
		return escape_nillable(escape, descriptor.elem)
	case .Struct:
		for field in descriptor.fields { if escape_nillable(escape, field.type) { return true } }
	}
	return false
}

@(private = "file")
escape_nil_add :: proc(escape: ^Escape, entity: check.Entity_Id, uninit: bool, path: Path_Id = 0) -> runtime.Allocator_Error {
	if entity == 0 || escape_nil_covered(escape, escape.nils[:], entity, path, uninit) { return nil }
	for escaped in escape.nil_escaped { if escaped == entity { return nil } }
	append(&escape.nils, Nil_Fact{entity, path, uninit}) or_return
	return nil
}

@(private = "file")
escape_nil_forget :: proc(escape: ^Escape, entity: check.Entity_Id) {
	for index := len(escape.nils) - 1; index >= 0; index -= 1 {
		if escape.nils[index].entity == entity { unordered_remove(&escape.nils, index) }
	}
}

@(private = "file")
escape_ident_entity :: proc(escape: ^Escape, node: syntax.Node_Index, view: check.View_Id = 0) -> check.Entity_Id {
	seen := escape.view if view == 0 else view
	current := escape_unparen(escape, node, seen)
	ast := escape_view_ast(escape, seen)
	if ast == nil || current == 0 || int(current) >= len(ast.nodes) || ast.nodes[current].kind != .Ident { return 0 }
	info := check.expression_info(escape.run.program, seen, current)
	if !escape_local(escape, info.entity) { return 0 }
	return info.entity
}

@(private = "file")
escape_is_nil_literal :: proc(escape: ^Escape, node: syntax.Node_Index) -> bool {
	current := escape_unparen(escape, node)
	if current == 0 || escape_ast(escape).nodes[current].kind != .Ident { return false }
	info := check.expression_info(escape.run.program, escape.view, current)
	return info.entity != 0 && escape.run.program.entities[info.entity].kind == .Nil
}

@(private = "file")
escape_is_undef :: proc(escape: ^Escape, node: syntax.Node_Index) -> bool {
	current := escape_unparen(escape, node)
	return current != 0 && escape_ast(escape).nodes[current].kind == .Undef
}

@(private = "package")
escape_note_declaration :: proc(escape: ^Escape, names: []syntax.Node_Index, values: []syntax.Node_Index) -> runtime.Allocator_Error {
	if !escape.nil_deref && !escape.uninit_vet { return nil }
	for name, index in names {
		entity := escape_ident_entity(escape, name)
		if entity == 0 { continue }
		escape_nil_forget(escape, entity)
		if len(values) == 0 && escape.nil_deref && escape_nillable(escape, escape.run.program.entities[entity].type) {
			escape_nil_add(escape, entity, false) or_return
		}
		if index >= len(values) { continue }
		if escape.uninit_vet && escape_is_undef(escape, values[index]) {
			seen := false
			for previous in escape.uninit_entities { if previous == entity { seen = true; break } }
			if !seen { append(&escape.uninit_entities, entity) or_return }
			escape_nil_add(escape, entity, true) or_return
		} else if escape.nil_deref && escape_is_nil_literal(escape, values[index]) {
			escape_nil_add(escape, entity, false) or_return
		} else if escape.nil_deref {
			source := escape_ident_entity(escape, values[index])
			if source != 0 && escape_nil_covered(escape, escape.nils[:], source, 0, false) { escape_nil_add(escape, entity, false) or_return }
		}
	}
	return nil
}

@(private = "package")
escape_note_store :: proc(escape: ^Escape, destination: syntax.Node_Index, value: syntax.Node_Index, replace: bool) -> runtime.Allocator_Error {
	if !escape.nil_deref && !escape.uninit_vet { return nil }
	entity, path, exact := escape_nil_location(escape, {escape.view, destination}) or_return
	if entity == 0 { return nil }
	source, source_path, _ := escape_nil_location(escape, {escape.view, value}) or_return
	propagated := make([dynamic]Nil_Fact, 0, escape.allocator) or_return
	if replace && exact {
		for fact in escape.nils {
			if source == 0 || fact.entity != source { continue }
			if escape_path_has_prefix(escape, source_path, fact.path) {
				append(&propagated, Nil_Fact{entity, path, fact.uninit}) or_return
			} else if escape_path_has_prefix(escape, fact.path, source_path) {
				suffix := escape_path_suffix(escape, fact.path, escape.graph.paths[source_path].depth) or_return
				projected := escape_path_concat(escape, path, suffix) or_return
				append(&propagated, Nil_Fact{entity, projected, fact.uninit}) or_return
			}
		}
	}
	escape_nil_kill(escape, entity, path) or_return
	if !replace || !exact { return nil }
	if escape.nil_deref && escape_is_nil_literal(escape, value) {
		escape_nil_add(escape, entity, false, path) or_return
	} else if escape.uninit_vet && escape_is_undef(escape, value) {
		escape_nil_add(escape, entity, true, path) or_return
	} else {
		for fact in propagated { escape_nil_add(escape, entity, fact.uninit, fact.path) or_return }
	}
	return nil
}

@(private = "file")
escape_record_use :: proc(escape: ^Escape, expression: check.Expression_Ref, kind: Nil_Use_Kind, definite: bool) -> runtime.Allocator_Error {
	if kind == .Uninit {
		if !escape.uninit_vet { return nil }
	} else if !escape.nil_deref { return nil }
	append(&escape.nil_uses, Nil_Use{expression, kind, definite}) or_return
	return nil
}

@(private = "package")
escape_note_expression :: proc(escape: ^Escape, expression: check.Expression_Ref) -> runtime.Allocator_Error {
	if !escape.nil_deref && !escape.uninit_vet { return nil }
	if expression.node == 0 { return nil }
	ast := escape_view_ast(escape, expression.view)
	if ast == nil || int(expression.node) >= len(ast.nodes) { return nil }
	node := expression.node
	expression_info := check.expression_info(escape.run.program, expression.view, node)
	if expression_info.mode == .Constant || expression_info.mode == .Type { return nil }
	root, path, _ := escape_nil_location(escape, expression) or_return
	if root != 0 {
		for tracked in escape.uninit_entities {
			if tracked == root {
				escape_record_use(escape, expression, .Uninit, escape_nil_covered(escape, escape.nils[:], root, path, true)) or_return
				break
			}
		}
		return escape_note_address(escape, expression)
	}
	#partial switch payload in ast.nodes[node].payload {
	case syntax.Paren_Expr:
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Ident:
		entity := escape_ident_entity(escape, node, expression.view)
		if entity == 0 { return nil }
		tracked := false
		for previous in escape.uninit_entities { if previous == entity { tracked = true; break } }
		if !tracked { return nil }
		return escape_record_use(escape, expression, .Uninit, escape_nil_covered(escape, escape.nils[:], entity, 0, true))
	case syntax.Deref_Expr:
		pointer := check.Expression_Ref{expression.view, escape_unparen(escape, payload.expr, expression.view)}
		entity := escape_ident_entity(escape, pointer.node, expression.view)
		escape_record_use(escape, pointer, .Deref, entity != 0 && escape_nil_covered(escape, escape.nils[:], entity, 0, false)) or_return
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Call_Expr:
		callee := check.Expression_Ref{expression.view, escape_unparen(escape, payload.expr, expression.view)}
		info := check.expression_info(escape.run.program, callee.view, callee.node)
		if info.type != 0 && (info.entity == 0 || escape.run.program.entities[info.entity].kind != .Builtin) {
			kind := escape_type(escape, info.type).kind
			if kind == .Procedure || kind == .Pointer || kind == .Multi_Pointer || kind == .Raw_Pointer {
				entity := escape_ident_entity(escape, callee.node, expression.view)
				escape_record_use(escape, callee, .Call, entity != 0 && escape_nil_covered(escape, escape.nils[:], entity, 0, false)) or_return
			}
		}
		escape_note_expression(escape, {expression.view, payload.expr}) or_return
		for argument in syntax.node_list(ast, payload.args) { escape_note_expression(escape, {expression.view, argument}) or_return }
	case syntax.Selector_Expr:
		base := check.expression_info(escape.run.program, expression.view, payload.expr)
		if base.type != 0 && escape_type(escape, base.type).kind == .Pointer {
			pointer := check.Expression_Ref{expression.view, escape_unparen(escape, payload.expr, expression.view)}
			entity := escape_ident_entity(escape, pointer.node, expression.view)
			escape_record_use(escape, pointer, .Deref, entity != 0 && escape_nil_covered(escape, escape.nils[:], entity, 0, false)) or_return
		}
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Index_Expr:
		base := check.expression_info(escape.run.program, expression.view, payload.expr)
		if base.type != 0 {
			kind: types.Kind
			if base.type != 0 { kind = escape_type(escape, base.type).kind }
			if kind == .Pointer || kind == .Multi_Pointer || kind == .Raw_Pointer {
				pointer := check.Expression_Ref{expression.view, escape_unparen(escape, payload.expr, expression.view)}
				entity := escape_ident_entity(escape, pointer.node, expression.view)
				escape_record_use(escape, pointer, .Deref, entity != 0 && escape_nil_covered(escape, escape.nils[:], entity, 0, false)) or_return
			}
		}
		escape_note_expression(escape, {expression.view, payload.expr}) or_return
		return escape_note_expression(escape, {expression.view, payload.index})
	case syntax.Unary_Expr:
		if payload.op.kind == .And {
			address := check.Expression_Ref{expression.view, payload.expr}
			escape_nil_escape(escape, address) or_return
			return escape_note_address(escape, address)
		}
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Slice_Expr:
		base := check.expression_info(escape.run.program, expression.view, payload.expr)
		kind: types.Kind
		if base.type != 0 { kind = escape_type(escape, base.type).kind }
		if kind == .Array || kind == .Enumerated_Array || kind == .Fixed_Capacity_Array {
			address := check.Expression_Ref{expression.view, payload.expr}
			escape_nil_escape(escape, address) or_return
			escape_note_address(escape, address) or_return
		} else { escape_note_expression(escape, {expression.view, payload.expr}) or_return }
		escape_note_expression(escape, {expression.view, payload.low}) or_return
		return escape_note_expression(escape, {expression.view, payload.high})
	case syntax.Binary_Expr:
		escape_note_expression(escape, {expression.view, payload.left}) or_return
		return escape_note_expression(escape, {expression.view, payload.right})
	case syntax.Or_Return_Expr:
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Or_Branch_Expr:
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Or_Else_Expr:
		escape_note_expression(escape, {expression.view, payload.x}) or_return
		return escape_note_expression(escape, {expression.view, payload.y})
	case syntax.Tag_Expr:
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Auto_Cast:
		return escape_note_expression(escape, {expression.view, payload.expr})
	case syntax.Type_Cast:
		return escape_note_expression(escape, {expression.view, payload.expr})
	}
	return nil
}

@(private = "file")
escape_nil_location :: proc(
	escape: ^Escape,
	expression: check.Expression_Ref,
) -> (
	entity: check.Entity_Id,
	path: Path_Id,
	exact: bool,
	err: runtime.Allocator_Error,
) {
	node := escape_unparen(escape, expression.node, expression.view)
	if node == 0 { return }
	ast := escape_view_ast(escape, expression.view)
	#partial switch payload in ast.nodes[node].payload {
	case syntax.Ident:
		entity = escape_ident_entity(escape, node, expression.view)
		exact = entity != 0
	case syntax.Selector_Expr:
		info := check.expression_info(escape.run.program, expression.view, node)
		if info.plan == 0 { return }
		place, ok := check.plan(escape.run.program, info.plan)^.(check.Place_Plan)
		if !ok { return }
		root_type := escape_operand_type(escape, place.root)
		if root_type == 0 || escape_type(escape, root_type).kind == .Pointer { return }
		switch root in place.root {
		case check.Expression_Ref:
			entity, path, exact = escape_nil_location(escape, root) or_return
		case check.Entity_Id:
			if escape_local(escape, root) { entity = root; exact = true }
		case check.Projection, check.Const_Id:
		}
		if entity == 0 { return }
		for step in place.path {
			if step.indirect || step.type == 0 { return 0, 0, false, nil }
			if escape_type(escape, step.type).raw_union { exact = false; continue }
			path = escape_path(
				escape,
				path,
				{kind = .Field, owner_type = types.resolve_named(escape.run.program.type_data, step.type), field_index = step.field_index},
			) or_return
		}
	case syntax.Index_Expr:
		info := check.expression_info(escape.run.program, expression.view, payload.expr)
		kind: types.Kind
		if info.type != 0 { kind = escape_type(escape, info.type).kind }
		if kind != .Array && kind != .Enumerated_Array && kind != .Fixed_Capacity_Array { return }
		entity, path, _ = escape_nil_location(escape, {expression.view, payload.expr}) or_return
		if entity != 0 { path = escape_path(escape, path, {kind = .Element}) or_return }
	}
	return
}

@(private = "file")
escape_nil_kill :: proc(escape: ^Escape, entity: check.Entity_Id, path: Path_Id) -> runtime.Allocator_Error {
	pieces := make([dynamic]Nil_Fact, 0, escape.allocator) or_return
	steps := escape_path_steps(escape, path) or_return
	for index := len(escape.nils) - 1; index >= 0; index -= 1 {
		fact := escape.nils[index]
		if fact.entity != entity || !escape_path_has_prefix(escape, path, fact.path) && !escape_path_has_prefix(escape, fact.path, path) { continue }
		unordered_remove(&escape.nils, index)
		fact_steps := escape_path_steps(escape, fact.path) or_return
		if len(fact_steps) > len(steps) { continue }
		type := escape_type_follow(escape, escape.run.program.entities[entity].type, fact_steps[:])
		prefix := fact.path
		for step in steps[len(fact_steps):] {
			if type == 0 { break }
			descriptor := escape_type(escape, type)
			if step.kind != .Field || descriptor.kind != .Struct || int(step.field_index) >= len(descriptor.fields) { break }
			for field, field_index in descriptor.fields {
				if field_index == int(step.field_index) || !fact.uninit && !escape_nillable(escape, field.type) { continue }
				other := escape_path(escape, prefix, {kind = .Field, owner_type = step.owner_type, field_index = u32(field_index)}) or_return
				append(&pieces, Nil_Fact{entity, other, fact.uninit}) or_return
			}
			type = descriptor.fields[step.field_index].type
			prefix = escape_path(escape, prefix, step) or_return
		}
	}
	for piece in pieces { escape_nil_add(escape, piece.entity, piece.uninit, piece.path) or_return }
	return nil
}

@(private = "file")
escape_nil_root :: proc(escape: ^Escape, expression: check.Expression_Ref) -> check.Entity_Id {
	node := escape_unparen(escape, expression.node, expression.view)
	if node == 0 { return 0 }
	ast := escape_view_ast(escape, expression.view)
	base: syntax.Node_Index
	#partial switch payload in ast.nodes[node].payload {
	case syntax.Ident:
		return escape_ident_entity(escape, node, expression.view)
	case syntax.Selector_Expr:
		info := check.expression_info(escape.run.program, expression.view, payload.expr)
		if info.type != 0 && escape_type(escape, info.type).kind == .Pointer { return 0 }
		return escape_nil_root(escape, {expression.view, payload.expr})
	case syntax.Index_Expr:
		base = payload.expr
	case syntax.Slice_Expr:
		base = payload.expr
	}
	if base == 0 { return 0 }
	info := check.expression_info(escape.run.program, expression.view, base)
	if info.type == 0 { return 0 }
	kind := escape_type(escape, info.type).kind
	if kind == .Array || kind == .Enumerated_Array || kind == .Fixed_Capacity_Array || kind == .Struct {
		return escape_nil_root(escape, {expression.view, base})
	}
	return 0
}

@(private = "file")
escape_nil_escape :: proc(escape: ^Escape, expression: check.Expression_Ref) -> runtime.Allocator_Error {
	if !escape.nil_deref && !escape.uninit_vet { return nil }
	entity := escape_nil_root(escape, expression)
	if entity == 0 { return nil }
	for previous in escape.nil_escaped { if previous == entity { return nil } }
	append(&escape.nil_escaped, entity) or_return
	escape_nil_forget(escape, entity)
	return nil
}

@(private = "package")
escape_note_address :: proc(escape: ^Escape, expression: check.Expression_Ref) -> runtime.Allocator_Error {
	if !escape.nil_deref && !escape.uninit_vet { return nil }
	node := escape_unparen(escape, expression.node, expression.view)
	if node == 0 { return nil }
	ast := escape_view_ast(escape, expression.view)
	#partial switch payload in ast.nodes[node].payload {
	case syntax.Ident:
		return nil
	case syntax.Selector_Expr:
		info := check.expression_info(escape.run.program, expression.view, payload.expr)
		base := check.Expression_Ref{expression.view, payload.expr}
		if info.type != 0 && escape_type(escape, info.type).kind == .Pointer { return escape_note_expression(escape, base) }
		return escape_note_address(escape, base)
	case syntax.Index_Expr:
		info := check.expression_info(escape.run.program, expression.view, payload.expr)
		kind: types.Kind
		if info.type != 0 { kind = escape_type(escape, info.type).kind }
		base := check.Expression_Ref{expression.view, payload.expr}
		if kind == .Array || kind == .Enumerated_Array || kind == .Fixed_Capacity_Array || kind == .Struct {
			escape_note_address(escape, base) or_return
		} else { escape_note_expression(escape, base) or_return }
		return escape_note_expression(escape, {expression.view, payload.index})
	case syntax.Deref_Expr:
		return escape_note_expression(escape, {expression.view, payload.expr})
	}
	return escape_note_expression(escape, expression)
}

@(private = "file")
escape_refine :: proc(escape: ^Escape, node: syntax.Node_Index, truth: bool) -> runtime.Allocator_Error {
	current := escape_unparen(escape, node)
	if current == 0 || !escape.nil_deref { return nil }
	ast := escape_ast(escape)
	#partial switch payload in ast.nodes[current].payload {
	case syntax.Unary_Expr:
		if payload.op.kind == .Not { return escape_refine(escape, payload.expr, !truth) }
	case syntax.Binary_Expr:
		if payload.op.kind == .And && truth {
			escape_refine(escape, payload.left, true) or_return
			return escape_refine(escape, payload.right, true)
		}
		if payload.op.kind == .Or && !truth {
			escape_refine(escape, payload.left, false) or_return
			return escape_refine(escape, payload.right, false)
		}
		if payload.op.kind != .Cmp_Eq && payload.op.kind != .Not_Eq { return nil }
		left := escape_unparen(escape, payload.left)
		right := escape_unparen(escape, payload.right)
		value := left
		if escape_is_nil_literal(escape, left) { value = right } else if !escape_is_nil_literal(escape, right) { return nil }
		entity := escape_ident_entity(escape, value)
		if entity == 0 { return nil }
		is_nil := (payload.op.kind == .Cmp_Eq) == truth
		if !is_nil {
			escape_nil_forget(escape, entity)
		} else if escape_nillable(escape, check.expression_info(escape.run.program, escape.view, value).type) {
			escape_nil_add(escape, entity, false) or_return
		}
	}
	return nil
}

@(private = "file")
escape_constant_true :: proc(escape: ^Escape, node: syntax.Node_Index) -> bool {
	if node == 0 { return false }
	info := check.expression_info(escape.run.program, escape.view, node)
	constant := check.constant(escape.run.program, info.constant)
	if constant == nil { return false }
	value, ok := constant.value.(bool)
	return ok && value
}

@(private = "package")
escape_if :: proc(escape: ^Escape, node: syntax.Node_Index, statement: syntax.If_Stmt) -> runtime.Allocator_Error {
	target := -1
	if statement.label != 0 { target = escape_push_target(escape, node, .Label) or_return }
	escape_statement(escape, statement.init) or_return
	condition := check.Expression_Ref{escape.view, statement.cond}
	escape_note_expression(escape, condition) or_return
	_ = escape_expression(escape, condition) or_return
	other := escape_capture(escape) or_return
	escape_refine(escape, statement.cond, true) or_return
	escape_statement(escape, statement.body) or_return
	then := escape_capture(escape) or_return
	escape_restore(escape, other) or_return
	escape_refine(escape, statement.cond, false) or_return
	escape_statement(escape, statement.else_stmt) or_return
	escape_join_live(escape, then) or_return
	if target >= 0 {
		escape_join_live(escape, escape.targets[target].breaks) or_return
		pop(&escape.targets)
	}
	return nil
}

@(private = "file")
escape_bind_range :: proc(escape: ^Escape, range: syntax.Node_Index, vals: []syntax.Node_Index) -> runtime.Allocator_Error {
	if range == 0 || len(vals) == 0 { return nil }
	value := escape_expression(escape, {escape.view, range}) or_return
	path := escape_path(escape, 0, {kind = .Element}) or_return
	projected := escape_project(escape, {escape.view, range}, value, path, read = true) or_return
	for val in vals {
		node := escape_unparen(escape, val)
		if node == 0 { continue }
		if escape_ast(escape).nodes[node].kind == .Unary_Expr { continue }
		entity := escape_ident_entity(escape, node)
		if entity == 0 { continue }
		if escape_plain(escape, escape.run.program.entities[entity].type) { continue }
		escape_store_operand(escape, entity, projected) or_return
		escape_nil_forget(escape, entity)
	}
	return nil
}

@(private = "package")
escape_switch :: proc(escape: ^Escape, node, body: syntax.Node_Index, exhaustive: bool) -> runtime.Allocator_Error {
	if body == 0 { return nil }
	ast := escape_ast(escape)
	if ast.nodes[body].kind != .Block_Stmt { return nil }
	target := escape_push_target(escape, node, .Switch) or_return
	entry := escape_capture(escape) or_return
	exit: Escape_State
	escape.fallen_live = false
	has_default := false
	clauses := syntax.node_list(ast, ast.nodes[body].payload.(syntax.Block_Stmt).stmts)
	for clause in clauses {
		if ast.nodes[clause].kind != .Case_Clause { continue }
		payload := ast.nodes[clause].payload.(syntax.Case_Clause)
		if payload.list.count == 0 { has_default = true }
		escape_restore(escape, entry) or_return
		if escape.fallen_live { escape_join_live(escape, escape.fallen) or_return }
		escape.fallen = {}
		escape.fallen_live = false
		escape_block(escape, clause, 0, syntax.node_list(ast, payload.body)) or_return
		escape_join_state(escape, &exit) or_return
	}
	escape.reachable = false
	escape_join_live(escape, exit) or_return
	if !has_default && !exhaustive { escape_join_live(escape, entry) or_return }
	escape_join_live(escape, escape.targets[target].breaks) or_return
	pop(&escape.targets)
	escape.fallen_live = false
	return nil
}

@(private = "package")
escape_named_results :: proc(escape: ^Escape, node: syntax.Node_Index) -> runtime.Allocator_Error {
	checked := escape.run.program.procedure_list[escape.run.procedures[escape.procedure].checked_index]
	if len(checked.results) == 0 { return nil }
	name := escape.run.program.entities[checked.results[0]].name
	if name == "" || name == "_" { return nil }
	for result in checked.results {
		escape_nil_forget(escape, result)
	}
	for result, result_index in checked.results {
		object := escape_object(escape, result) or_return
		text := escape.run.program.entities[result].name
		value := escape_project(escape, {escape.view, node}, escape.memory[object], 0, read = true) or_return
		escape_report_return(escape, check.Expression_Ref{escape.view, node}, value, text) or_return
		escape_note_result(escape, result_index, value) or_return
	}
	return nil
}

@(private = "package")
escape_or_return :: proc(escape: ^Escape, node: syntax.Node_Index) -> runtime.Allocator_Error {
	saved := escape_capture(escape) or_return
	escape_named_results(escape, node) or_return
	escape_run_defers(escape, 0) or_return
	escape_commit_stores(escape) or_return
	escape_restore(escape, saved) or_return
	return nil
}

@(private = "package")
escape_finish_procedure :: proc(escape: ^Escape, body: syntax.Node_Index) -> runtime.Allocator_Error {
	if escape_too_large(escape) { return nil }
	if escape.reachable {
		escape_named_results(escape, body) or_return
		escape_commit_stores(escape) or_return
	}
	if !escape.nil_deref && !escape.uninit_vet { return nil }
	seen := make([]bool, len(escape.nil_uses), escape.allocator) or_return
	for use, index in escape.nil_uses {
		if seen[index] { continue }
		definite := use.definite
		for other, other_index in escape.nil_uses {
			if other_index == index || other.expression != use.expression || other.kind != use.kind { continue }
			seen[other_index] = true
			definite &&= other.definite
		}
		if !definite { continue }
		text := escape_expression_text(escape, use.expression)
		reason: string
		switch use.kind {
		case .Deref:
			reason = fmt.aprintf("Dereferencing '%s', which is always nil here", text, allocator = escape.allocator)
		case .Call:
			reason = fmt.aprintf("Calling '%s', which is always nil here", text, allocator = escape.allocator)
		case .Uninit:
			reason = fmt.aprintf("Reading '%s' before anything is stored in it", text, allocator = escape.allocator)
		}
		append(escape_report_list(escape), Diagnostic{severity = .Error, source = escape_expression_span(escape, use.expression), reason = reason}) or_return
	}
	return nil
}

@(private = "package")
escape_loop :: proc(
	escape: ^Escape,
	node: syntax.Node_Index,
	cond, post, body, range: syntax.Node_Index,
	vals: []syntax.Node_Index,
) -> runtime.Allocator_Error {
	target := escape_push_target(escape, node, .Loop) or_return
	head := escape_capture(escape) or_return
	exit: Escape_State
	use_count := len(escape.nil_uses)
	settled := false
	for _ in 0 ..< 16 {
		for len(escape.nil_uses) > use_count { pop(&escape.nil_uses) }
		escape_restore(escape, head) or_return
		if cond != 0 { escape_note_expression(escape, {escape.view, cond}) or_return }
		may_exit := range != 0 || (cond != 0 && !escape_constant_true(escape, cond))
		if may_exit {
			saved := escape_capture(escape) or_return
			escape_refine(escape, cond, false) or_return
			escape_join_state(escape, &exit) or_return
			escape_restore(escape, saved) or_return
		}
		escape_refine(escape, cond, true) or_return
		escape_bind_range(escape, range, vals) or_return
		escape_statement(escape, body) or_return
		escape_join_live(escape, escape.targets[target].continues) or_return
		if escape.reachable && post != 0 { escape_statement(escape, post) or_return }
		if !(escape_join_state(escape, &head) or_return) {
			settled = true
			break
		}
	}
	escape.reachable = false
	escape_join_live(escape, escape.targets[target].breaks) or_return
	escape_join_live(escape, exit) or_return
	if !settled {
		for len(escape.nil_uses) > use_count { pop(&escape.nil_uses) }
		clear(&escape.nils)
	}
	pop(&escape.targets)
	return nil
}
