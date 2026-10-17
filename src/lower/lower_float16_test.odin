package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Procedure `() -> f16` returning `1.0 + 2^-11`; the exact sum is a tie between `1.0` and the next half, so it rounds to even `1.0`.
@(test)
float16_addition_rounds_ties_to_even :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	half := types.intern(&store, types.Type{kind = .Float, count = 2})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {half}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	left := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	right := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	sum := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = left, op = {kind = .Add}, right = right})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {sum})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(left) - 1] = {
		type     = half,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(right) - 1] = {
		type     = half,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(sum) - 1] = {
		type  = half,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.constant_table = fixture_clone(
		[]check.Constant {
			{},
			{type = half, value = check.Float_Value{bits = 0x3c00, width = 16}},
			{type = half, value = check.Float_Value{bits = 0x1000, width = 16}},
		},
		allocator,
	)

	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(0x3c00))
}
