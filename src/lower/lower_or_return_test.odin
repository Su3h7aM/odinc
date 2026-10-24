package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Procedure `() -> u8` running `value := pair() or_return` and returning `value`, where `pair() -> (u8, bool)` returns (7, true).
@(test)
call_or_return_declaration_yields_first_result :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte := types.intern(&store, types.Type{kind = .Integer, count = 1})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	probe_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {byte}})
	pair_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {byte, boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee})
	propagated := syntax.ast_add_node(&ast, .Or_Return_Expr, 0, 1, syntax.Or_Return_Expr{expr = call})
	value := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {value}), values = syntax.ast_add_list(&ast, {propagated})},
	)
	returned := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {returned})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration, result})})

	seven := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	ok := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	pair_return := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {seven, ok})})
	pair_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {pair_return})})

	entities := fixture_clone(
		[]check.Entity{{}, {kind = .Procedure, type = probe_signature}, {kind = .Procedure, type = pair_signature}, {kind = .Variable, type = byte}},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(callee) - 1] = {
		entity = 2,
		state  = .Checked,
	}
	facts[int(call) - 1] = {
		mode  = .No_Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(propagated) - 1] = {
		type  = byte,
		mode  = .Value,
		plan  = 3,
		state = .Checked,
	}
	facts[int(declaration) - 1] = {
		state = .Checked,
	}
	facts[int(value) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	facts[int(returned) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	facts[int(seven) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(pair_return) - 1] = {
		plan  = 4,
		state = .Checked,
	}
	facts[int(ok) - 1] = {
		type     = boolean,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, probe_signature, entities, facts, nil)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "probe", type = probe_signature},
			{entity = 2, kind = .Procedure, name = "pair", type = pair_signature},
		},
		allocator,
	)
	program.entity_symbols[1], program.entity_symbols[2] = 1, 2
	program.procedure_list = fixture_clone(
		[]check.Checked_Procedure {
			{entity = 1, symbol = 1, signature = probe_signature, convention = .Contextless, body = {1, body}, view = 1},
			{entity = 2, symbol = 2, signature = pair_signature, convention = .Contextless, body = {1, pair_body}, view = 1},
		},
		allocator,
	)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Call_Plan{callee = check.Entity_Id(2), entity = 2, results = fixture_clone([]types.Type_Id{byte, boolean}, allocator)},
			check.Exit_Plan{kind = .Return, values = fixture_clone([]check.Operand{check.Projection{check.Expression_Ref{1, call}, 1}}, allocator)},
			check.Propagation_Plan {
				operand = check.Expression_Ref{1, call},
				test = .Boolean_True,
				values = fixture_clone([]check.Operand{check.Projection{check.Expression_Ref{1, call}, 0}}, allocator),
				failure = 2,
			},
			check.Exit_Plan{kind = .Return, values = fixture_clone([]check.Operand{check.Const_Id(1), check.Const_Id(2)}, allocator)},
		},
		allocator,
	)
	seven_value: big.Int
	testing.expect_value(t, big.int_set_from_integer(&seven_value, 7, allocator = allocator), big.Error.None)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = byte, value = seven_value}, {type = boolean, value = true}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	if len(errors) != 0 {
		testing.expectf(t, false, "lowering reported %v", errors[0])
		return
	}
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	defer delete(actual.output)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(7))
}

// Procedure `(flag: bool) -> bool` running `flag or_return` and then returning true: a false flag exits with false.
@(test)
stored_or_return_exits_with_stored_status :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	boolean := types.intern(&store, types.Type{kind = .Bool})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {boolean}, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	flag := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	propagated := syntax.ast_add_node(&ast, .Or_Return_Expr, 0, 1, syntax.Or_Return_Expr{expr = flag})
	statement := syntax.ast_add_node(&ast, .Expr_Stmt, 0, 1, syntax.Expr_Stmt{expr = propagated})
	yes := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {yes})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {statement, result})})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = boolean}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(flag) - 1] = {
		type   = boolean,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(propagated) - 1] = {
		mode  = .No_Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(statement) - 1] = {
		state = .Checked,
	}
	facts[int(yes) - 1] = {
		type     = boolean,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, []check.Entity_Id{2})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Propagation_Plan{operand = check.Expression_Ref{1, flag}, test = .Boolean_True, failure = 2},
			check.Exit_Plan{kind = .Return, values = fixture_clone([]check.Operand{check.Expression_Ref{1, flag}}, allocator)},
		},
		allocator,
	)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = boolean, value = true}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	if len(errors) != 0 {
		testing.expectf(t, false, "lowering reported %v", errors[0])
		return
	}
	defer ir.module_destroy(&module)
	for expected in ([]u64{1, 0}) {
		actual, run_error := ir.interp_run(&module, module.functions[0], []u64{expected}, 1000, context.allocator)
		testing.expect_value(t, run_error, nil)
		testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
		testing.expect_value(t, actual.value, expected)
		delete(actual.output)
	}
}

// Procedure `() -> u8` running `value := pair() or_else boom()` and returning `value`, where `pair()` returns (7, false) and
// `boom()` is noreturn: the fallback runs `boom` and the arm ends there, so execution never reaches the return.
@(test)
or_else_noreturn_fallback_ends_its_arm :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte := types.intern(&store, types.Type{kind = .Integer, count = 1})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	probe_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {byte}})
	pair_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {byte, boolean}})
	boom_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	pair_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	pair_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = pair_callee})
	boom_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	boom_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = boom_callee})
	fallback := syntax.ast_add_node(&ast, .Or_Else_Expr, 0, 1, syntax.Or_Else_Expr{x = pair_call, y = boom_call})
	value := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {value}), values = syntax.ast_add_list(&ast, {fallback})},
	)
	returned := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {returned})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration, result})})

	seven := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	no := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	pair_return := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {seven, no})})
	pair_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {pair_return})})
	boom_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{})

	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = probe_signature},
			{kind = .Procedure, type = pair_signature},
			{kind = .Procedure, type = boom_signature},
			{kind = .Variable, type = byte},
		},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(pair_callee) - 1] = {
		entity = 2,
		state  = .Checked,
	}
	facts[int(pair_call) - 1] = {
		mode  = .No_Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(boom_callee) - 1] = {
		entity = 3,
		state  = .Checked,
	}
	facts[int(boom_call) - 1] = {
		mode  = .No_Value,
		plan  = 2,
		state = .Checked,
	}
	facts[int(seven) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(no) - 1] = {
		type     = boolean,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(fallback) - 1] = {
		type  = byte,
		mode  = .Value,
		plan  = 3,
		state = .Checked,
	}
	facts[int(pair_return) - 1] = {
		plan  = 5,
		state = .Checked,
	}
	facts[int(declaration) - 1] = {
		state = .Checked,
	}
	facts[int(value) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 4,
		state  = .Checked,
	}
	facts[int(returned) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 4,
		state  = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, probe_signature, entities, facts, nil)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "probe", type = probe_signature},
			{entity = 2, kind = .Procedure, name = "pair", type = pair_signature},
			{entity = 3, kind = .Procedure, name = "boom", type = boom_signature},
		},
		allocator,
	)
	program.entity_symbols[1], program.entity_symbols[2], program.entity_symbols[3] = 1, 2, 3
	seven_value: big.Int
	testing.expect_value(t, big.int_set_from_integer(&seven_value, 7, allocator = allocator), big.Error.None)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = byte, value = seven_value}, {type = boolean, value = false}}, allocator)
	program.procedure_list = fixture_clone(
		[]check.Checked_Procedure {
			{entity = 1, symbol = 1, signature = probe_signature, convention = .Contextless, body = {1, body}, view = 1},
			{entity = 2, symbol = 2, signature = pair_signature, convention = .Contextless, body = {1, pair_body}, view = 1},
			{entity = 3, symbol = 3, signature = boom_signature, convention = .Contextless, body = {1, boom_body}, view = 1},
		},
		allocator,
	)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Call_Plan{callee = check.Entity_Id(2), entity = 2, results = fixture_clone([]types.Type_Id{byte, boolean}, allocator)},
			check.Call_Plan{callee = check.Entity_Id(3), entity = 3},
			check.Propagation_Plan {
				operand = check.Expression_Ref{1, pair_call},
				test = .Boolean_True,
				values = fixture_clone([]check.Operand{check.Projection{check.Expression_Ref{1, pair_call}, 0}}, allocator),
				fallback_conversion = 0,
			},
			check.Exit_Plan{kind = .Return, values = fixture_clone([]check.Operand{check.Expression_Ref{1, value}}, allocator)},
			check.Exit_Plan{kind = .Return, values = fixture_clone([]check.Operand{check.Const_Id(1), check.Const_Id(2)}, allocator)},
		},
		allocator,
	)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	if len(errors) != 0 {
		testing.expectf(t, false, "lowering reported %v", errors[0])
		return
	}
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	defer delete(actual.output)
	testing.expect_value(t, run_error, nil)
	testing.expectf(t, actual.outcome == .Unreachable, "outcome %v, want Unreachable: the noreturn fallback must end the arm", actual.outcome)
}
