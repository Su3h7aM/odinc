package lower

import "base:runtime"
import "core:math/big"
import "core:math/bits"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
bit_intrinsics_match_reference_values :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	kinds := [?]check.Builtin_Kind{.Count_Ones, .Count_Zeros, .Count_Leading_Zeros, .Count_Trailing_Zeros, .Reverse_Bits, .Byte_Swap}
	inputs := [?]u16{0x0000, 0x0001, 0x8000, 0x1234, 0xffff}
	for kind in kinds {
		for input in inputs {
			actual, ok := run_unary_intrinsic(t, kind, u64(input), allocator)
			if !ok { continue }
			testing.expect_value(t, actual, u64(reference_unary_intrinsic(kind, input)))
		}
	}
}

// Procedure `(x: u16) -> u16` returning `kind(x)`.
@(private)
run_unary_intrinsic :: proc(t: ^testing.T, kind: check.Builtin_Kind, argument: u64, allocator: runtime.Allocator) -> (value: u64, ok: bool) {
	store := types.init()
	defer types.destroy(&store)
	word := types.intern(&store, types.Type{kind = .Integer, count = 2})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {word}, results = {word}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	parameter := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	callee := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	call := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = callee, args = syntax.ast_add_list(&ast, {parameter})})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {call})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = word}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(parameter) - 1] = {
		type   = word,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(callee) - 1] = {
		state = .Checked,
	}
	facts[int(call) - 1] = {
		type  = word,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{.None, kind}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Builtin_Plan{builtin = 1, arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, parameter}}, allocator)}},
		allocator,
	)
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return 0, false }
	defer ir.module_destroy(&module)
	outcome, run_error := ir.interp_run(&module, module.functions[0], {argument}, 1000, context.allocator)
	if !testing.expect_value(t, run_error, nil) || !testing.expect_value(t, outcome.outcome, ir.Interp_Outcome.Value) { return 0, false }
	return outcome.value, true
}

@(private)
reference_unary_intrinsic :: proc(kind: check.Builtin_Kind, input: u16) -> u16 {
	#partial switch kind {
	case .Count_Ones:
		return u16(bits.count_ones(input))
	case .Count_Zeros:
		return 16 - u16(bits.count_ones(input))
	case .Count_Leading_Zeros:
		return u16(bits.leading_zeros(input))
	case .Count_Trailing_Zeros:
		return u16(bits.trailing_zeros(input))
	case .Byte_Swap:
		return bits.byte_swap(input)
	}
	reversed: u16
	for index in 0 ..< 16 {
		reversed |= ((input >> uint(index)) & 1) << uint(15 - index)
	}
	return reversed
}

// Procedure `() -> u16` running `volatile_store(&guard, 7)`, `mem_zero(&guard, 2)`, `atomic_add(&guard, 5)` and
// returning `atomic_exchange(&guard, 30)`: the result is 5 only if each effect is applied in order.
@(test)
memory_intrinsics_update_global_in_order :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	word := types.intern(&store, types.Type{kind = .Integer, count = 2})
	length := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = word})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, results = {word}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)

	global := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = global})
	seven := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	two := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	five := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	thirty := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	arguments := [4][2]syntax.Node_Index{{address, seven}, {address, two}, {address, five}, {address, thirty}}
	callees: [4]syntax.Node_Index
	calls: [4]syntax.Node_Index
	for index in 0 ..< 4 {
		callees[index] = syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		calls[index] = syntax.ast_add_node(
			&ast,
			.Call_Expr,
			0,
			1,
			syntax.Call_Expr{expr = callees[index], args = syntax.ast_add_list(&ast, arguments[index][:])},
		)
	}
	statements: [4]syntax.Node_Index
	for index in 0 ..< 3 {
		statements[index] = syntax.ast_add_node(&ast, .Expr_Stmt, 0, 1, syntax.Expr_Stmt{expr = calls[index]})
	}
	statements[3] = syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {calls[3]})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, statements[:])})

	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = word}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(global) - 1] = {
		type   = word,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(address) - 1] = {
		type  = pointer,
		mode  = .Value,
		state = .Checked,
	}
	facts[int(seven) - 1] = {
		type     = word,
		mode     = .Constant,
		constant = 1,
		state    = .Checked,
	}
	facts[int(two) - 1] = {
		type     = length,
		mode     = .Constant,
		constant = 2,
		state    = .Checked,
	}
	facts[int(five) - 1] = {
		type     = word,
		mode     = .Constant,
		constant = 3,
		state    = .Checked,
	}
	facts[int(thirty) - 1] = {
		type     = word,
		mode     = .Constant,
		constant = 4,
		state    = .Checked,
	}
	for index in 0 ..< 4 {
		facts[int(callees[index]) - 1] = {
			state = .Checked,
		}
		mode := check.Addressing_Mode.No_Value if index < 3 else .Value
		result := word if index != 1 else types.Type_Id(0)
		facts[int(calls[index]) - 1] = {
			type  = result,
			mode  = mode,
			plan  = check.Plan_Id(index + 1),
			state = .Checked,
		}
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, nil)
	program.builtin_kinds = fixture_clone([]check.Builtin_Kind{.None, .Volatile_Store, .Mem_Zero, .Atomic_Add, .Atomic_Exchange}, allocator)
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Builtin_Plan {
				builtin = 1,
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, address}, check.Expression_Ref{1, seven}}, allocator),
			},
			check.Builtin_Plan {
				builtin = 2,
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, address}, check.Expression_Ref{1, two}}, allocator),
			},
			check.Builtin_Plan {
				builtin = 3,
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, address}, check.Expression_Ref{1, five}}, allocator),
			},
			check.Builtin_Plan {
				builtin = 4,
				arguments = fixture_clone([]check.Operand{check.Expression_Ref{1, address}, check.Expression_Ref{1, thirty}}, allocator),
			},
		},
		allocator,
	)
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "expression", type = signature},
			{entity = 2, kind = .Global, name = "guard", type = word, alignment = 2},
		},
		allocator,
	)
	program.entity_symbols = fixture_clone([]check.Symbol_Id{0, 1, 2}, allocator)
	program.global_list = fixture_clone([]check.Global{{entity = 2, symbol = 2, type = word, alignment = 2}}, allocator)
	values := [4]i64{7, 2, 5, 30}
	constants: [4]big.Int
	for &constant, index in constants {
		testing.expect_value(t, big.int_set_from_integer(&constant, values[index], allocator = allocator), big.Error.None)
	}
	program.constant_table = fixture_clone(
		[]check.Constant {
			{},
			{type = word, value = constants[0]},
			{type = length, value = constants[1]},
			{type = word, value = constants[2]},
			{type = word, value = constants[3]},
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
	testing.expect_value(t, actual.value, u64(5))
}
