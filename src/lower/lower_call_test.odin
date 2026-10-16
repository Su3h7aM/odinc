package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
direct_calls_preserve_argument_order_conversions_and_syscall_memory :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	word := types.intern(&store, types.Type{kind = .Integer, count = 8})
	byte := types.intern(&store, types.Type{kind = .Integer, count = 1})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = byte})
	array := types.intern(&store, types.Type{kind = .Array, elem = byte, count = 1})
	main_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	next_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {pointer, byte}, results = {byte}})
	subtract_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {byte, byte}, results = {byte}})
	initialize_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {pointer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	next_pointer := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	next_value := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	next_old := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	next_dereference := syntax.ast_add_node(&ast, .Deref_Expr, 0, 1, syntax.Deref_Expr{expr = next_pointer})
	next_declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {next_old}), values = syntax.ast_add_list(&ast, {next_dereference})},
	)
	next_store := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {next_dereference}), rhs = syntax.ast_add_list(&ast, {next_value})},
	)
	next_return := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {next_old})})
	next_body := syntax.ast_add_node(
		&ast,
		.Block_Stmt,
		0,
		1,
		syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {next_declaration, next_store, next_return})},
	)

	left := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	right := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	difference := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = right, op = {kind = .Sub}, right = left})
	subtract_return := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {difference})})
	subtract_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {subtract_return})})

	initialize_pointer := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	initialize_dereference := syntax.ast_add_node(&ast, .Deref_Expr, 0, 1, syntax.Deref_Expr{expr = initialize_pointer})
	byte_one := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	initialize_store := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {initialize_dereference}), rhs = syntax.ast_add_list(&ast, {byte_one})},
	)
	initialize_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {initialize_store})})

	buffer := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	zero := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	one := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	exit_number := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	first_value := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	second_value := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	buffer_declaration := syntax.ast_add_node(&ast, .Value_Decl, 0, 1, syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {buffer})})
	buffer_index := syntax.ast_add_node(&ast, .Index_Expr, 0, 1, syntax.Index_Expr{expr = buffer, index = zero})
	buffer_address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = buffer_index})
	next_name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	initialize_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{args = syntax.ast_add_list(&ast, {buffer_address})})
	initialize_statement := syntax.ast_add_node(&ast, .Expr_Stmt, 0, 1, syntax.Expr_Stmt{expr = initialize_call})
	first_call := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr{expr = next_name, args = syntax.ast_add_list(&ast, {buffer_address, first_value})},
	)
	second_call := syntax.ast_add_node(
		&ast,
		.Call_Expr,
		0,
		1,
		syntax.Call_Expr{expr = next_name, args = syntax.ast_add_list(&ast, {buffer_address, second_value})},
	)
	subtract_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{args = syntax.ast_add_list(&ast, {first_call, second_call})})
	buffer_store := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {buffer_index}), rhs = syntax.ast_add_list(&ast, {subtract_call})},
	)
	address_word := syntax.ast_add_node(&ast, .Type_Cast, 0, 1, syntax.Type_Cast{expr = buffer_address})
	write_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{args = syntax.ast_add_list(&ast, {one, one, address_word, one})})
	exit_code := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = write_call, op = {kind = .Sub}, right = one})
	exit_call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{args = syntax.ast_add_list(&ast, {exit_number, exit_code})})
	exit_statement := syntax.ast_add_node(&ast, .Expr_Stmt, 0, 1, syntax.Expr_Stmt{expr = exit_call})
	main_body := syntax.ast_add_node(
		&ast,
		.Block_Stmt,
		0,
		1,
		syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {buffer_declaration, initialize_statement, buffer_store, exit_statement})},
	)
	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = main_signature},
			{kind = .Procedure, type = next_signature},
			{kind = .Procedure, type = subtract_signature},
			{kind = .Variable, type = array},
			{kind = .Variable, type = pointer},
			{kind = .Variable, type = byte},
			{kind = .Variable, type = byte},
			{kind = .Variable, type = byte},
			{kind = .Variable, type = byte},
			{kind = .Procedure, type = initialize_signature},
			{kind = .Variable, type = pointer},
		},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	for entry in ([]struct {
			node:   syntax.Node_Index,
			entity: check.Entity_Id,
		}{{next_pointer, 5}, {next_value, 6}, {next_old, 7}, {left, 8}, {right, 9}, {initialize_pointer, 11}, {buffer, 4}, {next_name, 2}}) {
		facts[int(entry.node) - 1] = {
			type   = entities[entry.entity].type,
			entity = entry.entity,
			mode   = .Variable,
			state  = .Checked,
		}
	}
	for entry in ([]struct {
			node: syntax.Node_Index,
			type: types.Type_Id,
			plan: check.Plan_Id,
		}{{next_dereference, byte, 0}, {difference, byte, 0}, {initialize_dereference, byte, 0}, {buffer_index, byte, 0}, {buffer_address, pointer, 0}, {first_call, byte, 2}, {second_call, byte, 3}, {subtract_call, byte, 4}, {address_word, word, 7}, {write_call, word, 8}, {exit_code, word, 0}, {exit_call, word, 9}}) {
		facts[int(entry.node) - 1] = {
			type  = entry.type,
			plan  = entry.plan,
			mode  = .Value,
			state = .Checked,
		}
	}
	facts[int(initialize_call) - 1] = {
		plan  = 1,
		mode  = .No_Value,
		state = .Checked,
	}
	for entry in ([]struct {
			node:     syntax.Node_Index,
			constant: check.Const_Id,
		}{{zero, 1}, {one, 2}, {exit_number, 3}, {first_value, 4}, {second_value, 5}, {byte_one, 6}}) {
		facts[int(entry.node) - 1] = {
			type     = word if entry.constant != 6 else byte,
			constant = entry.constant,
			mode     = .Constant,
			state    = .Checked,
		}
	}
	program := expression_fixture(&ast, &store, allocator, main_body, main_signature, entities, facts, nil)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "main", type = main_signature},
			{entity = 2, kind = .Procedure, name = "next", type = next_signature},
			{entity = 3, kind = .Procedure, name = "subtract", type = subtract_signature},
			{entity = 10, kind = .Procedure, name = "initialize", type = initialize_signature},
		},
		allocator,
	)
	program.entity_symbols[1], program.entity_symbols[2], program.entity_symbols[3], program.entity_symbols[10] = 1, 2, 3, 4
	program.procedure_list = fixture_clone(
		[]check.Checked_Procedure {
			{entity = 1, symbol = 1, signature = main_signature, convention = .Contextless, body = {1, main_body}, view = 1},
			{entity = 2, symbol = 2, signature = next_signature, convention = .Contextless, body = {1, next_body}, view = 1, parameters = {5, 6}},
			{entity = 3, symbol = 3, signature = subtract_signature, convention = .Contextless, body = {1, subtract_body}, view = 1, parameters = {8, 9}},
			{entity = 10, symbol = 4, signature = initialize_signature, convention = .Contextless, body = {1, initialize_body}, view = 1, parameters = {11}},
		},
		allocator,
	)
	program.constant_table = make([]check.Constant, 7, allocator)
	for value, index in ([]u64{0, 1, 60, 98, 99, 1}) {
		integer: big.Int
		big.int_set_from_integer(&integer, value, allocator = allocator)
		program.constant_table[index + 1] = {
			type  = word if index != 5 else byte,
			value = integer,
		}
	}
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{.None, .Syscall}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Call_Plan{callee = check.Entity_Id(10), entity = 10, arguments = {{value = check.Expression_Ref{1, buffer_address}, parameter = 11}}},
			check.Call_Plan {
				callee = check.Expression_Ref{1, next_name},
				entity = 2,
				arguments = {
					{value = check.Expression_Ref{1, buffer_address}, parameter = 5},
					{value = check.Const_Id(4), parameter = 6, conversion = 5, evaluation_order = 1},
				},
				results = {byte},
			},
			check.Call_Plan {
				callee = check.Expression_Ref{1, next_name},
				entity = 2,
				arguments = {
					{value = check.Expression_Ref{1, buffer_address}, parameter = 5},
					{value = check.Const_Id(5), parameter = 6, conversion = 6, evaluation_order = 1},
				},
				results = {byte},
			},
			check.Call_Plan {
				callee = check.Entity_Id(3),
				entity = 3,
				arguments = {
					{value = check.Expression_Ref{1, second_call}, parameter = 9, evaluation_order = 20},
					{value = check.Expression_Ref{1, first_call}, parameter = 8, evaluation_order = 10},
				},
				results = {byte},
			},
			check.Conversion_Plan{kind = .Assignment, source = check.Const_Id(4), target = byte},
			check.Conversion_Plan{kind = .Assignment, source = check.Const_Id(5), target = byte},
			check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, buffer_address}, target = word},
			check.Builtin_Plan{builtin = 1, arguments = {check.Const_Id(2), check.Const_Id(2), check.Expression_Ref{1, address_word}, check.Const_Id(2)}},
			check.Builtin_Plan{builtin = 1, arguments = {check.Const_Id(3), check.Expression_Ref{1, exit_code}}},
		},
		allocator,
	)
	module: ir.Module
	errors, err := lower_program(&program, &module, worker_count = 3)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	defer delete(actual.output)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Exit)
	testing.expect_value(t, actual.value, u64(0))
	testing.expect_value(t, string(actual.output), "a")

	retained := program.plan_table[4]
	for malformed in ([]check.Call_Plan{{callee = check.Entity_Id(3), entity = 3, arguments = {{value = check.Expression_Ref{1, first_call}, parameter = 8}, {value = check.Expression_Ref{1, second_call}, parameter = 9}}, results = {byte}}, {callee = check.Entity_Id(3), entity = 3, arguments = {{value = check.Expression_Ref{1, first_call}, parameter = 999}, {value = check.Expression_Ref{1, second_call}, parameter = 9, evaluation_order = 1}}, results = {byte}}}) {
		program.plan_table[4] = malformed
		rejected: ir.Module
		failures, allocation_error := lower_program(&program, &rejected)
		testing.expect_value(t, allocation_error, nil)
		if allocation_error == nil {
			if testing.expect_value(t, len(failures), 1) {
				testing.expect_value(t, failures[0].code, Lower_Code.Unsupported)
				testing.expect_value(t, failures[0].feature, Lower_Feature.Call_Argument)
			}
			ir.module_destroy(&rejected)
		}
		delete(failures)
	}
	program.plan_table[4] = retained
}
