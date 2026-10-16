package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

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
		lower_fail(state, node, .Defer)
	case .Range_Stmt:
		lower_range(state, node, ast_node.payload.(syntax.Range_Stmt))
	case .Unroll_Range_Stmt:
		lower_fail(state, node, .Range)
	case .Switch_Stmt, .Type_Switch_Stmt, .Case_Clause:
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
				if len(exit.values) == 0 {
					if len(state.job.function.signatures[state.job.function.signature].results) != 0 { lower_fail(state, node, .Result); return }
					ir.emit_return(state.builder)
					return
				}
				if len(exit.values) != 1 { lower_fail(state, node, .Result); return }
				value := lower_operand(state, exit.values[0])
				lower_scalar_return(state, node, value)
			} else { lower_fail(state, node, .Body) }
			return
		}
		values := syntax.node_list(state.ast, ast_node.payload.(syntax.Return_Stmt).results)
		signature := state.job.function.signatures[state.job.function.signature]
		if len(values) != len(signature.results) || len(values) > 1 { lower_fail(state, node, .Result); return }
		if len(values) == 0 { ir.emit_return(state.builder); return }
		value := lower_value(state, values[0])
		lower_scalar_return(state, node, value)
	case .Empty_Stmt:
	case:
		lower_fail(state, node, .Body)
	}
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
	ir.emit_return(state.builder, result)
}
