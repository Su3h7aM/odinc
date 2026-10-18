package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Type_Switch_Subject :: struct {
	address:    ir.Node_Id,
	variants:   []types.Type_Id,
	is_any:     bool,
	union_form: types.Union_Form,
	layout:     types.Union_Layout,
}

// Each case type tests the subject and jumps to its clause body; the clauses fall through to the end, not to each other.
@(private)
lower_type_switch :: proc(state: ^Procedure_State, node: syntax.Node_Index, statement: syntax.Type_Switch_Stmt) {
	scope := local_scope(state)
	defer leave_local_scope(state, scope)
	info, _ := check.expression_info(state.job.program, state.view, node)
	if info.plan == 0 {
		lower_fail(state, node, .Switch)
		return
	}
	plan := check.plan(state.job.program, info.plan)
	type_switch, is_type_switch := plan^.(check.Type_Switch_Plan)
	if !is_type_switch {
		lower_fail(state, node, .Switch)
		return
	}
	subject_address := lower_operand(state, type_switch.subject)
	if state.failed || state.job.function.error != nil { return }
	subject, subject_ok := lower_type_switch_subject(state, node, type_switch.subject_type, subject_address)
	if !subject_ok { return }
	clauses := syntax.node_list(state.ast, state.ast.nodes[statement.body].payload.(syntax.Block_Stmt).stmts)
	allocator := virtual.arena_allocator(&state.job.function.arena)
	bodies, bodies_error := make([]ir.Jump_Target_Id, len(clauses), allocator)
	if bodies_error != nil { state.job.function.error = bodies_error; return }
	end := ir.jump_target_make(state.builder)
	if !push_control_target(state, {node = {state.job.procedure.body.file, node}, break_target = end}) { return }
	defer pop(&state.control_targets)
	default_body := -1
	for clause, index in type_switch.clauses {
		bodies[index] = ir.jump_target_make(state.builder)
		if len(clause.variants) == 0 { default_body = index }
		for variant in clause.variants {
			condition := lower_type_switch_test(state, node, subject, variant)
			if state.failed || state.job.function.error != nil { return }
			branch := ir.branch_if(state.builder, condition)
			ir.enter_arm(state.builder, branch, 0)
			ir.jump_to(state.builder, bodies[index])
			ir.enter_arm(state.builder, branch, 1)
		}
	}
	if default_body >= 0 {
		ir.jump_to(state.builder, bodies[default_body])
	} else {
		ir.jump_to(state.builder, end)
	}
	for clause_node, index in clauses {
		if !ir.seal_target(state.builder, bodies[index]) { continue }
		body_scope := local_scope(state)
		case_clause := state.ast.nodes[clause_node].payload.(syntax.Case_Clause)
		lower_type_switch_bind(state, type_switch.clauses[index], type_switch.reference, subject)
		for statement_node in syntax.node_list(state.ast, case_clause.body) { lower_statement(state, statement_node) }
		leave_local_scope(state, body_scope)
		if state.failed || state.job.function.error != nil { return }
		ir.jump_to(state.builder, end)
	}
	ir.seal_target(state.builder, end)
}

@(private)
lower_type_switch_subject :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	type: types.Type_Id,
	address: ir.Node_Id,
) -> (
	subject: Type_Switch_Subject,
	ok: bool,
) {
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, type))
	subject = Type_Switch_Subject {
		address    = address,
		variants   = descriptor.variants,
		is_any     = descriptor.kind == .Any,
		union_form = descriptor.union_form,
	}
	if subject.is_any { return subject, true }
	layout, layout_error := types.union_layout(store, types.resolve_named(store, type))
	if layout_error != .None || (layout.tag_size == 0 && subject.union_form != .Maybe_Pointer) {
		lower_fail(state, node, .Switch)
		return subject, false
	}
	subject.layout = layout
	return subject, true
}

// A maybe-pointer union tests its pointer word, a tagged union its tag word, and an any its typeid word.
// Tags are the variant index, plus one unless the union is no_nil; the nil case is tag 0.
@(private)
lower_type_switch_test :: proc(state: ^Procedure_State, node: syntax.Node_Index, subject: Type_Switch_Subject, variant: types.Type_Id) -> ir.Node_Id {
	function := state.job.function
	is_nil := variant == types.TYPE_UNTYPED_NIL
	if subject.is_any {
		typeid_word := lower_load_word(state, ir.ptr_offset(function, subject.address, 8), .I64)
		expected := ir.const_int(function, .I64, 0)
		if !is_nil { expected = lower_runtime_typeid(state, node, variant) }
		if state.failed { return 0 }
		return ir.compare(function, .Eq, typeid_word, expected)
	}
	if subject.union_form == .Maybe_Pointer {
		pointer := lower_load_word(state, subject.address, .Ptr)
		kind := ir.Node_Kind.Eq if is_nil else ir.Node_Kind.Ne
		return ir.compare(function, kind, pointer, ir.const_int(function, .Ptr, 0))
	}
	tag_type := tag_value_type(subject.layout.tag_size)
	expected := i64(0)
	for candidate, index in subject.variants {
		if !is_nil && candidate == variant {
			expected = i64(index)
			if subject.union_form != .No_Nil { expected += 1 }
		}
	}
	tag_address := ir.ptr_offset(function, subject.address, subject.layout.variant_block_size)
	tag := lower_load_word(state, tag_address, tag_type)
	return ir.compare(function, .Eq, tag, ir.const_int(function, tag_type, expected))
}

@(private)
tag_value_type :: proc(size: i64) -> ir.Value_Type {
	switch size {
	case 1:
		return .I8
	case 2:
		return .I16
	case 4:
		return .I32
	}
	return .I64
}

// A single-type clause binds the payload; `nil`, multi-type and default clauses bind the whole subject.
@(private)
lower_type_switch_bind :: proc(state: ^Procedure_State, clause: check.Type_Switch_Clause, reference: bool, subject: Type_Switch_Subject) {
	if clause.entity == 0 { return }
	if len(clause.variants) != 1 || clause.variants[0] == types.TYPE_UNTYPED_NIL {
		if reference {
			bind_local_address(state, clause.entity, subject.address)
		} else {
			bind_local(state, clause.entity, subject.address, true)
		}
		return
	}
	payload_address := subject.address
	if subject.is_any { payload_address = lower_load_word(state, subject.address, .Ptr) }
	if reference {
		bind_local_address(state, clause.entity, payload_address)
		return
	}
	bind_local(state, clause.entity, lower_load(state, payload_address, clause.variants[0]), true)
}

@(private)
bind_local_address :: proc(state: ^Procedure_State, entity: check.Entity_Id, address: ir.Node_Id) {
	assert(entity != 0 && state.locals[entity].kind == .None)
	if _, err := append(&state.local_entities, entity); err != nil { state.job.function.error = err; return }
	state.locals[entity] = {
		kind    = .Address,
		address = address,
	}
}
