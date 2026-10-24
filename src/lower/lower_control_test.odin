package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
loop_branches_preserve_assignments_and_continue_post :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	limit := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	counter := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	sum := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	zero := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	one := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	two := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	six := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	sum_decl := syntax.ast_add_node(&ast, .Value_Decl, 0, 1, syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {sum})})
	counter_decl := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {counter}), values = syntax.ast_add_list(&ast, {zero})},
	)
	condition := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = counter, op = {kind = .Lt}, right = limit})
	skip := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = counter, op = {kind = .Cmp_Eq}, right = two})
	stop := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = counter, op = {kind = .Cmp_Eq}, right = six})
	continue_stmt := syntax.ast_add_node(&ast, .Branch_Stmt, 0, 1, syntax.Branch_Stmt{token = {kind = .Continue}})
	break_stmt := syntax.ast_add_node(&ast, .Branch_Stmt, 0, 1, syntax.Branch_Stmt{token = {kind = .Break}})
	skip_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {continue_stmt})})
	stop_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {break_stmt})})
	skip_if := syntax.ast_add_node(&ast, .If_Stmt, 0, 1, syntax.If_Stmt{cond = skip, body = skip_body})
	stop_if := syntax.ast_add_node(&ast, .If_Stmt, 0, 1, syntax.If_Stmt{cond = stop, body = stop_body})
	accumulate := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Add_Eq}, lhs = syntax.ast_add_list(&ast, {sum}), rhs = syntax.ast_add_list(&ast, {counter})},
	)
	post := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Add_Eq}, lhs = syntax.ast_add_list(&ast, {counter}), rhs = syntax.ast_add_list(&ast, {one})},
	)
	loop_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {skip_if, stop_if, accumulate})})
	loop := syntax.ast_add_node(&ast, .For_Stmt, 0, 1, syntax.For_Stmt{init = counter_decl, cond = condition, post = post, body = loop_body})
	collapsed_break := syntax.ast_add_node(&ast, .Branch_Stmt, 0, 1, syntax.Branch_Stmt{token = {kind = .Break}})
	collapsed_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {collapsed_break})})
	collapsed_loop := syntax.ast_add_node(&ast, .For_Stmt, 0, 1, syntax.For_Stmt{body = collapsed_body})
	return_stmt := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {sum})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {sum_decl, loop, collapsed_loop, return_stmt})})
	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = signature},
			{kind = .Variable, type = integer},
			{kind = .Variable, type = integer},
			{kind = .Variable, type = integer},
		},
		allocator,
	)
	interval_expression := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = zero, op = {kind = .Range_Half}, right = limit})
	interval_names := syntax.ast_add_list(&ast, {counter})
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(limit) - 1] = {
		type   = integer,
		entity = 2,
		mode   = .Value,
		state  = .Checked,
	}
	facts[int(counter) - 1] = {
		type   = integer,
		entity = 3,
		mode   = .Variable,
		state  = .Checked,
	}
	facts[int(sum) - 1] = {
		type   = integer,
		entity = 4,
		mode   = .Variable,
		state  = .Checked,
	}
	for node in ([?]syntax.Node_Index{condition, skip, stop}) {facts[int(node) - 1] = {
			type  = boolean,
			mode  = .Value,
			state = .Checked,
		}}
	for node, index in ([?]syntax.Node_Index{zero, one, two, six}) {facts[int(node) - 1] = {
			type     = integer,
			constant = check.Const_Id(index + 1),
			mode     = .Constant,
			state    = .Checked,
		}}
	facts[int(continue_stmt) - 1] = {
		plan  = 1,
		state = .Checked,
	}
	facts[int(break_stmt) - 1] = {
		plan  = 2,
		state = .Checked,
	}
	facts[int(collapsed_break) - 1] = {
		plan  = 3,
		state = .Checked,
	}
	facts[int(return_stmt) - 1] = {
		plan  = 4,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Exit_Plan{kind = .Continue, target = {1, loop}},
			check.Exit_Plan{kind = .Break, target = {1, loop}},
			check.Exit_Plan{kind = .Break, target = {1, collapsed_loop}},
			check.Exit_Plan{kind = .Return, values = fixture_clone([]check.Operand{check.Entity_Id(4)}, allocator)},
		},
		allocator,
	)
	program.constant_table = make([]check.Constant, 5, allocator)
	for number, index in ([?]i64{0, 1, 2, 6}) {
		value: big.Int
		testing.expect_value(t, big.int_set_from_integer(&value, number, allocator = allocator), big.Error.None)
		program.constant_table[index + 1] = {
			type  = integer,
			value = value,
		}
	}
	for loop_operator in ([?]syntax.Token_Kind{.Invalid, .Range_Half, .Range_Full}) {
		if loop_operator != .Invalid {
			ast.nodes[loop].kind = .Range_Stmt
			ast.nodes[loop].payload = syntax.Range_Stmt {
				vals = interval_names,
				expr = interval_expression,
				body = loop_body,
			}
			ast.nodes[interval_expression].payload = syntax.Binary_Expr {
				left = zero,
				op = {kind = loop_operator},
				right = limit,
			}
		}
		module: ir.Module
		errors, _, err := lower_program(&program, &module)
		defer delete(errors)
		if !testing.expect_value(t, err, nil) { continue }
		defer ir.module_destroy(&module)
		if !testing.expect_value(t, len(errors), 0) { continue }
		cases := [?]struct {
			limit, expected, inclusive: u64,
		}{{0, 0, 0}, {1, 0, 1}, {3, 1, 4}, {6, 13, 13}, {10, 13, 13}}
		for test_case in cases {
			actual, run_error := ir.interp_run(&module, module.functions[0], {test_case.limit}, 10000, context.allocator)
			testing.expect_value(t, run_error, nil)
			testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
			testing.expect_value(t, actual.value, test_case.inclusive if loop_operator == .Range_Full else test_case.expected)
		}
	}
}
