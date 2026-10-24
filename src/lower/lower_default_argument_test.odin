package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// An omitted trailing argument takes its default from the view that declared it, not from the calling view.
@(test)
omitted_default_argument_lowers_in_declaring_view :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	pick_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer, integer}, results = {integer}})
	main_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	right := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	pick_return := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {right})})
	pick_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {pick_return})})

	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee})
	main_return := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {call})})
	main_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {main_return})})

	// One node, two views: the calling view holds a stale constant, the declaring view the default.
	default_value := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = main_signature},
			{kind = .Procedure, type = pick_signature},
			{kind = .Variable, type = integer},
			{kind = .Variable, type = integer},
		},
		allocator,
	)
	calling_facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	calling_facts[int(right) - 1] = {
		type   = integer,
		entity = 4,
		mode   = .Value,
		state  = .Checked,
	}
	calling_facts[int(call) - 1] = {
		type  = integer,
		plan  = 1,
		mode  = .Value,
		state = .Checked,
	}
	calling_facts[int(default_value) - 1] = {
		type     = integer,
		constant = 3,
		mode     = .Constant,
		state    = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, main_body, main_signature, entities, calling_facts, nil)
	declaring_facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	declaring_facts[int(default_value) - 1] = {
		type     = integer,
		constant = 2,
		mode     = .Constant,
		state    = .Checked,
	}
	declaring := expression_fixture(&ast, &store, allocator, main_body, main_signature, entities, declaring_facts, nil)
	program.typed_views = fixture_clone([]check.Typed_View{{}, program.typed_views[1], declaring.typed_views[1]}, allocator)

	program.constant_table = make([]check.Constant, 4, allocator)
	for value, index in ([]u64{1, 7, 9}) {
		integer_value: big.Int
		big.int_set_from_integer(&integer_value, value, allocator = allocator)
		program.constant_table[index + 1] = {
			type  = integer,
			value = integer_value,
		}
	}
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "main", type = main_signature},
			{entity = 2, kind = .Procedure, name = "pick", type = pick_signature},
		},
		allocator,
	)
	program.entity_symbols[1], program.entity_symbols[2] = 1, 2
	program.procedure_list = fixture_clone(
		[]check.Checked_Procedure {
			{entity = 1, symbol = 1, signature = main_signature, convention = .Contextless, body = {1, main_body}, view = 1},
			{entity = 2, symbol = 2, signature = pick_signature, convention = .Contextless, body = {1, pick_body}, view = 1, parameters = {3, 4}},
		},
		allocator,
	)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Call_Plan {
				callee = check.Entity_Id(2),
				entity = 2,
				arguments = {
					{value = check.Const_Id(1), parameter = 3},
					{value = check.Expression_Ref{2, default_value}, parameter = 4, evaluation_order = 1},
				},
				results = {integer},
			},
		},
		allocator,
	)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if len(errors) != 0 {
		testing.expectf(t, false, "lowering failed with feature %v at node %v", errors[0].feature, errors[0].node.node)
		return
	}
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(7))
}
