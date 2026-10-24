package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Empty dynamic array and map literals allocate nothing; they lower to a zeroed header, so len reads zero.
@(test)
empty_dynamic_array_literal_lowers_to_zeroed_header :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	dyn_array := types.intern(&store, types.Type{kind = .Dynamic_Array, elem = integer})
	backing := types.intern(&store, types.Type{kind = .Array, elem = integer, count = 0})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	literal := syntax.ast_add_node(&ast, .Comp_Lit, 0, 1, syntax.Comp_Lit{})
	length := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {length})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(literal) - 1] = {
		type  = dyn_array,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(length) - 1] = {
		type  = integer,
		mode  = .Value,
		plan  = 2,
		state = .Checked,
	}
	facts[int(result) - 1] = {
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{.None, .Len}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Dynamic_Array_Literal_Plan{type = dyn_array, backing = check.Aggregate_Plan{type = backing}},
			check.Builtin_Plan{builtin = 1, arguments = {check.Expression_Ref{1, literal}}},
		},
		allocator,
	)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	defer delete(actual.output)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(0))
}

@(test)
empty_map_literal_lowers_to_zeroed_header :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	table := types.intern(&store, types.Type{kind = .Map, index = integer, elem = integer})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	literal := syntax.ast_add_node(&ast, .Comp_Lit, 0, 1, syntax.Comp_Lit{})
	length := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {length})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(literal) - 1] = {
		type  = table,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(length) - 1] = {
		type  = integer,
		mode  = .Value,
		plan  = 2,
		state = .Checked,
	}
	facts[int(result) - 1] = {
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{.None, .Len}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Map_Literal_Plan{type = table}, check.Builtin_Plan{builtin = 1, arguments = {check.Expression_Ref{1, literal}}}},
		allocator,
	)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	defer delete(actual.output)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(0))
}
