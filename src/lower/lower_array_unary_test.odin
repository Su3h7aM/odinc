package lower

import "base:runtime"
import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Array_Unary_Term :: struct {
	temp:   int,
	lane:   int,
	weight: i64,
}

@(test)
array_unary_minus_negates_each_lane :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	array := types.intern(&store, types.Type{kind = .Array, elem = integer, count = 3})
	first, second, third := big.Int{}, big.Int{}, big.Int{}
	big.int_set_from_integer(&first, i64(1), allocator = allocator)
	big.int_set_from_integer(&second, i64(-2), allocator = allocator)
	big.int_set_from_integer(&third, i64(3), allocator = allocator)
	array_unary_check(
		t,
		allocator,
		&store,
		integer,
		array,
		integer,
		[]check.Constant{{type = integer, value = first}, {type = integer, value = second}, {type = integer, value = third}},
		[]syntax.Token_Kind{.Sub},
		[]Array_Unary_Term{{temp = 0, lane = 0, weight = 1}, {temp = 0, lane = 1, weight = 10}, {temp = 0, lane = 2, weight = 100}},
		false,
		u64(max(u32)) + 1 - 281,
	)
}

@(test)
array_unary_plus_copies_and_not_flips_each_lane :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	array := types.intern(&store, types.Type{kind = .Array, elem = integer, count = 3})
	first, second, third := big.Int{}, big.Int{}, big.Int{}
	big.int_set_from_integer(&first, i64(1), allocator = allocator)
	big.int_set_from_integer(&second, i64(-2), allocator = allocator)
	big.int_set_from_integer(&third, i64(3), allocator = allocator)
	array_unary_check(
		t,
		allocator,
		&store,
		integer,
		array,
		integer,
		[]check.Constant{{type = integer, value = first}, {type = integer, value = second}, {type = integer, value = third}},
		[]syntax.Token_Kind{.Add, .Xor},
		[]Array_Unary_Term {
			{temp = 0, lane = 1, weight = 1},
			{temp = 1, lane = 0, weight = 10},
			{temp = 1, lane = 1, weight = 100},
			{temp = 1, lane = 2, weight = 1000},
		},
		false,
		u64(max(u32)) + 1 - 3922,
	)
}

@(test)
array_unary_minus_negates_float_lane :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	float := types.intern(&store, types.Type{kind = .Float, count = 4})
	array := types.intern(&store, types.Type{kind = .Array, elem = float, count = 3})
	array_unary_check(
		t,
		allocator,
		&store,
		float,
		array,
		float,
		[]check.Constant {
			{type = float, value = check.Float_Value{bits = 0x3fc00000, width = 32}},
			{type = float, value = check.Float_Value{bits = 0xc0000000, width = 32}},
			{type = float, value = check.Float_Value{bits = 0x40500000, width = 32}},
		},
		[]syntax.Token_Kind{.Sub},
		[]Array_Unary_Term{{temp = 0, lane = 0, weight = 0}},
		false,
		u64(0xbfc00000),
	)
}

@(test)
array_unary_not_of_boolean_lane_reads_true :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	boolean := types.intern(&store, types.Type{kind = .Bool})
	integer := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	array := types.intern(&store, types.Type{kind = .Array, elem = boolean, count = 3})
	array_unary_check(
		t,
		allocator,
		&store,
		boolean,
		array,
		integer,
		[]check.Constant{{type = boolean, value = true}, {type = boolean, value = false}, {type = boolean, value = true}},
		[]syntax.Token_Kind{.Xor},
		[]Array_Unary_Term{{temp = 0, lane = 1, weight = 0}},
		true,
		u64(1),
	)
}

@(private)
array_unary_check :: proc(
	t: ^testing.T,
	allocator: runtime.Allocator,
	store: ^types.Store,
	elem, array, result: types.Type_Id,
	lanes: []check.Constant,
	operators: []syntax.Token_Kind,
	terms: []Array_Unary_Term,
	cast_lane: bool,
	expected: u64,
) {
	index_integer := types.intern(store, types.Type{kind = .Integer, count = 8, signed = true})
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, results = {result}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	lane_nodes := make([]syntax.Node_Index, len(lanes), allocator)
	for _, index in lanes {
		lane_nodes[index] = syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	}
	source := syntax.ast_add_node(&ast, .Comp_Lit, 0, 1, syntax.Comp_Lit{elems = syntax.ast_add_list(&ast, lane_nodes)})
	name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {name}), values = syntax.ast_add_list(&ast, {source})},
	)
	operations := make([]syntax.Node_Index, len(operators), allocator)
	temporaries := make([]syntax.Node_Index, len(operators), allocator)
	statements := make([]syntax.Node_Index, 2 + len(operators), allocator)
	statements[0] = declaration
	entities := make([]check.Entity, 3 + len(operators), allocator)
	entities[1] = {
		kind = .Procedure,
		type = signature,
	}
	entities[2] = {
		kind = .Variable,
		type = array,
	}
	for operator, index in operators {
		operations[index] = syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = operator}, expr = name})
		temporaries[index] = syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		statements[1 + index] = syntax.ast_add_node(
			&ast,
			.Value_Decl,
			0,
			1,
			syntax.Value_Decl {
				is_mutable = true,
				names = syntax.ast_add_list(&ast, {temporaries[index]}),
				values = syntax.ast_add_list(&ast, {operations[index]}),
			},
		)
		entities[3 + index] = {
			kind = .Variable,
			type = array,
		}
	}
	offsets := make([]syntax.Node_Index, len(terms), allocator)
	indexes := make([]syntax.Node_Index, len(terms), allocator)
	for term, index in terms {
		offsets[index] = syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
		indexes[index] = syntax.ast_add_node(&ast, .Index_Expr, 0, 1, syntax.Index_Expr{expr = temporaries[term.temp], index = offsets[index]})
	}
	coefficients, products, sums: []syntax.Node_Index
	final: syntax.Node_Index
	if cast_lane {
		final = syntax.ast_add_node(&ast, .Type_Cast, 0, 1, syntax.Type_Cast{expr = indexes[0]})
	} else if len(terms) == 1 {
		final = indexes[0]
	} else {
		coefficients = make([]syntax.Node_Index, len(terms), allocator)
		products = make([]syntax.Node_Index, len(terms), allocator)
		sums = make([]syntax.Node_Index, len(terms) - 1, allocator)
		combined: syntax.Node_Index
		for _, index in terms {
			coefficients[index] = syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
			products[index] = syntax.ast_add_node(
				&ast,
				.Binary_Expr,
				0,
				1,
				syntax.Binary_Expr{left = indexes[index], op = {kind = .Mul}, right = coefficients[index]},
			)
			if index == 0 {
				combined = products[0]
			} else {
				sums[index - 1] = syntax.ast_add_node(
					&ast,
					.Binary_Expr,
					0,
					1,
					syntax.Binary_Expr{left = combined, op = {kind = .Add}, right = products[index]},
				)
				combined = sums[index - 1]
			}
		}
		final = combined
	}
	outcome := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {final})})
	statements[1 + len(operators)] = outcome
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, statements)})
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	for lane_node, index in lane_nodes {
		facts[int(lane_node) - 1] = {
			type     = elem,
			mode     = .Constant,
			constant = check.Const_Id(1 + index),
			state    = .Checked,
		}
	}
	facts[int(source) - 1] = {
		type  = array,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(name) - 1] = {
		type   = array,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(declaration) - 1] = {
		state = .Checked,
	}
	for operation, index in operations {
		facts[int(operation) - 1] = {
			type  = array,
			mode  = .Value,
			state = .Checked,
		}
		facts[int(temporaries[index]) - 1] = {
			type   = array,
			mode   = .Variable,
			entity = check.Entity_Id(3 + index),
			state  = .Checked,
		}
		facts[int(statements[1 + index]) - 1] = {
			state = .Checked,
		}
	}
	for offset, index in offsets {
		facts[int(offset) - 1] = {
			type     = index_integer,
			mode     = .Constant,
			constant = check.Const_Id(1 + len(lanes) + index),
			state    = .Checked,
		}
		facts[int(indexes[index]) - 1] = {
			type  = elem,
			mode  = .Variable,
			plan  = 2,
			state = .Checked,
		}
	}
	if cast_lane {
		facts[int(final) - 1] = {
			type  = result,
			mode  = .Value,
			plan  = 3,
			state = .Checked,
		}
	} else if len(terms) > 1 {
		for coefficient, index in coefficients {
			facts[int(coefficient) - 1] = {
				type     = result,
				mode     = .Constant,
				constant = check.Const_Id(1 + len(lanes) + len(terms) + index),
				state    = .Checked,
			}
			facts[int(products[index]) - 1] = {
				type  = result,
				mode  = .Value,
				state = .Checked,
			}
		}
		for sum in sums {
			facts[int(sum) - 1] = {
				type  = result,
				mode  = .Value,
				state = .Checked,
			}
		}
	}
	facts[int(body) - 1] = {
		state = .Checked,
	}
	values := make([]check.Operand, len(lanes), allocator)
	field_indices := make([]u32, len(lanes), allocator)
	for _, index in lanes {
		values[index] = check.Operand(check.Const_Id(1 + index))
		field_indices[index] = u32(index)
	}
	aggregate := check.Aggregate_Plan {
		type          = array,
		values        = fixture_clone(values, allocator),
		field_indices = fixture_clone(field_indices, allocator),
	}
	bounds := check.Bounds_Plan {
		kind   = .Index,
		policy = .Disabled,
	}
	program := expression_fixture(&ast, store, allocator, body, signature, entities, facts, nil)
	if cast_lane {
		conversion := check.Conversion_Plan {
			kind   = .Cast,
			source = check.Operand(check.Expression_Ref{view = 1, node = indexes[0]}),
			target = result,
		}
		program.plan_table = fixture_clone([]check.Plan{{}, aggregate, bounds, conversion}, allocator)
	} else {
		program.plan_table = fixture_clone([]check.Plan{{}, aggregate, bounds}, allocator)
	}
	constants := make([]check.Constant, 1 + len(lanes) + len(terms) + (len(terms) if len(terms) > 1 && !cast_lane else 0), allocator)
	for lane, index in lanes {
		constants[1 + index] = lane
	}
	cursor := 1 + len(lanes)
	for term, index in terms {
		digit: big.Int
		big.int_set_from_integer(&digit, i64(term.lane), allocator = allocator)
		constants[cursor + index] = {
			type  = index_integer,
			value = digit,
		}
	}
	cursor += len(terms)
	if len(terms) > 1 && !cast_lane {
		for term, index in terms {
			magnitude: big.Int
			big.int_set_from_integer(&magnitude, term.weight, allocator = allocator)
			constants[cursor + index] = {
				type  = result,
				value = magnitude,
			}
		}
	}
	program.constant_table = fixture_clone(constants, allocator)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, err, nil) { return }
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], nil, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, expected)
}
