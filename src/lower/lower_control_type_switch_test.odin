package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:syntax"
import "oc:types"

// Assignments inside a type-switch body must be visible to loop variable
// collection, or the loop back-edge drops the update and the loop never ends.
@(test)
type_switch_body_assignments_are_loop_carried :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	target := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	zero := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	assign := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {target}), rhs = syntax.ast_add_list(&ast, {zero})},
	)
	default_clause := syntax.ast_add_node(&ast, .Case_Clause, 0, 1, syntax.Case_Clause{body = syntax.ast_add_list(&ast, {assign})})
	switch_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {default_clause})})
	type_switch := syntax.ast_add_node(&ast, .Type_Switch_Stmt, 0, 1, syntax.Type_Switch_Stmt{body = switch_body})
	trunk := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(target) - 1] = {
		type   = integer,
		entity = 2,
		mode   = .Variable,
		state  = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, trunk, signature, entities, facts, nil)
	job := Procedure_Job {
		program = &program,
	}
	state := Procedure_State {
		job    = &job,
		ast    = &ast,
		view   = 1,
		locals = make(map[check.Entity_Id]Local_Binding, allocator),
	}
	state.locals[2] = {
		kind     = .Variable,
		variable = 1,
	}
	assigned := make([]bool, 2, allocator)
	scan_assigned_variables(&state, type_switch, assigned)
	testing.expect(t, assigned[1])
}
