package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_statement :: proc(state: ^Procedure_State, node: syntax.Node_Index) {
	if node == 0 || state.failed || state.builder.control == 0 || state.job.function.error != nil { return }
	ast_node := state.ast.nodes[node]
	#partial switch ast_node.kind {
	case .Block_Stmt:
		lower_block(state, node, ast_node.payload.(syntax.Block_Stmt))
	case .If_Stmt:
		lower_if(state, node, ast_node.payload.(syntax.If_Stmt))
	case .For_Stmt:
		lower_for(state, node, ast_node.payload.(syntax.For_Stmt))
	case .Branch_Stmt:
		lower_branch(state, node, ast_node.payload.(syntax.Branch_Stmt))
	case .When_Stmt:
		lower_when(state, node, ast_node.payload.(syntax.When_Stmt))
	case .Defer_Stmt:
		if _, err := append(&state.defers, node); err != nil { state.job.function.error = err }
	case .Range_Stmt:
		lower_range(state, node, ast_node.payload.(syntax.Range_Stmt))
	case .Unroll_Range_Stmt:
		lower_fail(state, node, .Range)
	case .Switch_Stmt:
		lower_switch(state, node, ast_node.payload.(syntax.Switch_Stmt))
	case .Type_Switch_Stmt, .Case_Clause:
		lower_fail(state, node, .Switch)
	case .Value_Decl:
		lower_local_declaration(state, node, ast_node.payload.(syntax.Value_Decl))
	case .Assign_Stmt:
		lower_local_assignment(state, node, ast_node.payload.(syntax.Assign_Stmt))
	case .Expr_Stmt:
		lower_value(state, ast_node.payload.(syntax.Expr_Stmt).expr)
	case .Return_Stmt:
		info, ok := check.expression_info(state.job.program, state.view, node)
		if ok && info.plan != 0 {
			plan := check.plan(state.job.program, info.plan)
			assert(plan != nil)
			if exit, found := plan^.(check.Exit_Plan); found {
				assert(exit.kind == .Return)
				lower_return(state, node, exit.values, exit.conversions)
			} else { lower_fail(state, node, .Body) }
			return
		}
		values := syntax.node_list(state.ast, ast_node.payload.(syntax.Return_Stmt).results)
		store := check.type_store(state.job.program)
		descriptor := types.get(store, types.resolve_named(store, state.job.procedure.signature))
		if len(values) != len(descriptor.results) || len(values) > 1 { lower_fail(state, node, .Result); return }
		if len(values) == 0 {
			run_deferred(state, 0)
			ir.emit_return(state.builder)
			return
		}
		value := lower_value(state, values[0])
		lower_last_result(state, node, value, descriptor.results[0])
	case .Empty_Stmt:
	case:
		lower_fail(state, node, .Body)
	}
}

// lower_return returns explicit operands, or the named results on a bare return. Explicit values are also stored
// into the named results, so deferred statements can read them. The returned values are read before the deferred
// statements run, as official lb_build_return_stmt does.
@(private)
lower_return :: proc(state: ^Procedure_State, node: syntax.Node_Index, operands: []check.Operand, conversions: []check.Plan_Id) {
	job := state.job
	store := check.type_store(job.program)
	descriptor := types.get(store, types.resolve_named(store, job.procedure.signature))
	if len(descriptor.results) == 0 {
		if len(operands) != 0 { lower_fail(state, node, .Result); return }
		run_deferred(state, 0)
		ir.emit_return(state.builder)
		return
	}
	named := job.procedure.results
	if len(operands) == 0 && len(named) == 0 { lower_fail(state, node, .Result); return }
	if len(operands) != 0 && len(operands) != len(descriptor.results) { lower_fail(state, node, .Result); return }
	allocator := virtual.arena_allocator(&job.function.arena)
	values, err := make([]ir.Node_Id, len(descriptor.results), allocator)
	if err != nil { job.function.error = err; return }
	if len(operands) == 0 {
		for entity, index in named { values[index] = lower_entity_value(state, entity) }
	} else {
		for operand, index in operands {
			if index < len(conversions) && conversions[index] != 0 {
				values[index] = lower_declared_conversion(state, node, conversions[index])
			} else {
				values[index] = lower_operand(state, operand, descriptor.results[index])
			}
			if state.failed || job.function.error != nil { return }
		}
		for entity, index in named { store_result_entity(state, entity, values[index]) }
	}
	lower_result_values(state, node, values)
}

@(private)
store_result_entity :: proc(state: ^Procedure_State, entity: check.Entity_Id, value: ir.Node_Id) {
	binding := state.locals[entity]
	if binding.kind == .Variable {
		ir.variable_set(state.builder, binding.variable, value)
		return
	}
	lower_store(state, binding.address, value, state.job.program.entities[entity].type)
}

// lower_result_values stores every value but the last through the hidden result pointers,
// then returns the last value as the physical plan of a split return requires.
@(private)
lower_result_values :: proc(state: ^Procedure_State, node: syntax.Node_Index, values: []ir.Node_Id) {
	last := len(values) - 1
	if len(values) != len(state.result_pointers) + 1 { lower_fail(state, node, .Result); return }
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, state.job.procedure.signature))
	for value, index in values[:last] {
		lower_store(state, state.result_pointers[index], value, descriptor.results[index])
		if state.failed || state.job.function.error != nil { return }
	}
	lower_last_result(state, node, values[last], descriptor.results[last])
}

@(private)
lower_scalar_return :: proc(state: ^Procedure_State, node: syntax.Node_Index, value: ir.Node_Id) {
	if state.failed || state.job.function.error != nil { return }
	signature := state.job.function.signatures[state.job.function.signature]
	if len(signature.results) != 1 { lower_fail(state, node, .Result); return }
	result_type := signature.results[0].type
	result := value
	if state.job.function.nodes.type[result] == .Bool && result_type == .I8 { result = ir.convert(state.job.function, .Zext, result, .I8) }
	if state.job.function.nodes.type[result] != result_type { lower_fail(state, node, .Result); return }
	run_deferred(state, 0)
	if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
	ir.emit_return(state.builder, result)
}
