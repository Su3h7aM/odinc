package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Procedure `() -> bool` running `sum, overflowed := overflow_add(200, 100)` on `u8` and returning `overflowed`.
@(test)
overflow_add_tuple_reports_wrapped_overflow :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte := types.intern(&store, types.Type{kind = .Integer, count = 1})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	left := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	right := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {left, right})})
	sum := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	overflowed := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {sum, overflowed}), values = syntax.ast_add_list(&ast, {call})},
	)
	returned := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {returned})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration, result})})

	entities := fixture_clone(
		[]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = byte}, {kind = .Variable, type = boolean}},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(left) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(right) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(callee) - 1] = {
		state = .Checked,
	}
	facts[int(call) - 1] = {
		mode  = .No_Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(sum) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(overflowed) - 1] = {
		type   = boolean,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	facts[int(declaration) - 1] = {
		state = .Checked,
	}
	facts[int(returned) - 1] = {
		type   = boolean,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{.None, .Overflow_Add}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = 1,
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, left}, check.Expression_Ref{1, right}}, allocator),
				results = fixture_clone([]types.Type_Id{byte, boolean}, allocator),
			},
		},
		allocator,
	)
	values: [2]big.Int
	testing.expect_value(t, big.int_set_from_integer(&values[0], 200, allocator = allocator), big.Error.None)
	testing.expect_value(t, big.int_set_from_integer(&values[1], 100, allocator = allocator), big.Error.None)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = byte, value = values[0]}, {type = byte, value = values[1]}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(1))
}

// Procedure `() -> bool` exchanging `guard: u8` from 0 to 7 with `.Acquire` order, then from 0 to 9 with `.Seq_Cst`;
// it returns the second success flag, false because the first exchange already stored 7.
@(test)
compare_exchange_explicit_orders_apply_in_sequence :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte := types.intern(&store, types.Type{kind = .Integer, count = 1})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = byte})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	guard_first := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = guard_first})
	first_expected := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_desired := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_success := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_failure := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_call := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr{expr = first_callee, args = syntax.ast_add_list(&ast, {first_address, first_expected, first_desired, first_success, first_failure})},
	)
	first_old := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_flag := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	first_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {first_old, first_flag}), values = syntax.ast_add_list(&ast, {first_call})},
	)

	guard_second := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = guard_second})
	second_expected := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_desired := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_success := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_failure := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_call := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr {
			expr = second_callee,
			args = syntax.ast_add_list(&ast, {second_address, second_expected, second_desired, second_success, second_failure}),
		},
	)
	second_old := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_flag := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	second_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {second_old, second_flag}), values = syntax.ast_add_list(&ast, {second_call})},
	)
	returned := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {returned})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {first_declaration, second_declaration, result})})

	// Entities: 1 procedure, 2 guard, 3 first old, 4 first flag, 5 second old, 6 second flag.
	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = signature},
			{kind = .Variable, type = byte},
			{kind = .Variable, type = byte},
			{kind = .Variable, type = boolean},
			{kind = .Variable, type = byte},
			{kind = .Variable, type = boolean},
		},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(guard_first) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(guard_second) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(first_address) - 1] = {
		type  = pointer,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(second_address) - 1] = {
		type  = pointer,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(first_expected) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(second_expected) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(first_desired) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(second_desired) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 3,
		state    = .Checked,
	}
	facts[int(first_success) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 4,
		state    = .Checked,
	}
	facts[int(first_failure) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 5,
		state    = .Checked,
	}
	facts[int(second_success) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 6,
		state    = .Checked,
	}
	facts[int(second_failure) - 1] = {
		type     = byte,
		mode     = .Constant,
		constant = 6,
		state    = .Checked,
	}
	facts[int(first_callee) - 1] = {
		state = .Checked,
	}
	facts[int(second_callee) - 1] = {
		state = .Checked,
	}
	facts[int(first_call) - 1] = {
		mode  = .No_Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(second_call) - 1] = {
		mode  = .No_Value,
		plan  = 2,
		state = .Checked,
	}
	facts[int(first_old) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	facts[int(first_flag) - 1] = {
		type   = boolean,
		mode   = .Variable,
		entity = 4,
		state  = .Checked,
	}
	facts[int(second_old) - 1] = {
		type   = byte,
		mode   = .Variable,
		entity = 5,
		state  = .Checked,
	}
	facts[int(second_flag) - 1] = {
		type   = boolean,
		mode   = .Variable,
		entity = 6,
		state  = .Checked,
	}
	facts[int(first_declaration) - 1] = {
		state = .Checked,
	}
	facts[int(second_declaration) - 1] = {
		state = .Checked,
	}
	facts[int(returned) - 1] = {
		type   = boolean,
		mode   = .Variable,
		entity = 6,
		state  = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{.None, .Atomic_Compare_Exchange_Strong_Explicit}, allocator)
	results := fixture_clone([]types.Type_Id{byte, boolean}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = 1,
				arguments = fixture_clone(
					[]check.Operand {
						check.Expression_Ref{1, first_address},
						check.Expression_Ref{1, first_expected},
						check.Expression_Ref{1, first_desired},
						check.Expression_Ref{1, first_success},
						check.Expression_Ref{1, first_failure},
					},
					allocator,
				),
				results = results,
			},
			check.Builtin_Plan {
				builtin = 1,
				arguments = fixture_clone(
					[]check.Operand {
						check.Expression_Ref{1, second_address},
						check.Expression_Ref{1, second_expected},
						check.Expression_Ref{1, second_desired},
						check.Expression_Ref{1, second_success},
						check.Expression_Ref{1, second_failure},
					},
					allocator,
				),
				results = results,
			},
		},
		allocator,
	)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "expression", type = signature},
			{entity = 2, kind = .Global, name = "guard", type = byte, alignment = 1},
		},
		allocator,
	)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1, 2}, allocator)
	program.global_list = fixture_clone([]check.Global{{entity = 2, symbol = 2, type = byte, alignment = 1}}, allocator)
	// Orders: 0 zero, 1 expected and first success, 2 desired, 3 second desired, 4 Acquire, 5 Relaxed, 6 Seq_Cst.
	values := [7]i64{0, 0, 7, 9, 2, 0, 5}
	constants: [7]big.Int
	for &constant, index in constants {
		testing.expect_value(t, big.int_set_from_integer(&constant, values[index], allocator = allocator), big.Error.None)
	}
	program.constant_table = fixture_clone(
		[]check.Constant {
			{},
			{type = byte, value = constants[0]},
			{type = byte, value = constants[2]},
			{type = byte, value = constants[3]},
			{type = byte, value = constants[4]},
			{type = byte, value = constants[5]},
			{type = byte, value = constants[6]},
		},
		allocator,
	)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
	defer ir.module_destroy(&module)
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(0))
}
