package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
when_branch_declarations_stay_visible_after_the_when :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	parameter_use := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {name}), values = syntax.ast_add_list(&ast, {parameter_use})},
	)
	inner := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration})})
	when_statement := syntax.ast_add_node(&ast, .When_Stmt, 0, 1, syntax.When_Stmt{body = inner})
	result := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	ret := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {result})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {when_statement, ret})})
	entities := fixture_clone(
		[]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}, {kind = .Variable, type = integer}},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(parameter_use) - 1] = {
		type   = integer,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(name) - 1] = {
		type   = integer,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	facts[int(inner) - 1] = {
		state = .Checked,
	}
	facts[int(result) - 1] = {
		type   = integer,
		mode   = .Value,
		entity = 3,
		state  = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	module: ir.Module
	errors, _, err := lower_program(&program, &module, allocator)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], {u64(7)}, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(7))
}
